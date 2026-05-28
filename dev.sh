#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_REPO_TAG="${IMAGE_REPO_TAG:-mcp-pandoc:latest}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  run [stdio|http]     Run the MCP server locally (default: stdio)
  build                Build Docker image
  deploy-fc            Build, push, and deploy to Aliyun Function Compute using s tool
  test                 Run local integration tests

Environment Variables:
  MCP_PANDOC_AUTH_TOKEN        Bearer token for HTTP auth (required for http mode)
  MCP_PANDOC_UPLOAD_DIR        Upload directory (default: /tmp/uploads)
  MCP_PANDOC_UPLOAD_TTL_DAYS   File TTL in days (default: 7)
  MCP_PANDOC_UPLOAD_MAX_SIZE_MB Max upload dir size in MiB (default: 2048)
  MCP_PANDOC_GC_INTERVAL_SECONDS Min interval between GC runs in seconds (default: 60)
  IMAGE_REPO_TAG               Docker image repo:tag (default: mcp-pandoc:latest)
  TEST_BASE_URL                Base URL for tests (default: http://localhost:8080)

Setup:
  1. Copy s.yaml.example to s.yaml and edit with your ACR/FC settings
  2. Configure s tool account: s config add

Examples:
  $(basename "$0") run http
  $(basename "$0") build
  $(basename "$0") deploy-fc
  $(basename "$0") test
  TEST_BASE_URL=https://your-fc-trigger-url $(basename "$0") test
EOF
}

cmd_run() {
    local transport="${1:-stdio}"
    export MCP_PANDOC_TRANSPORT="$transport"

    if [[ "$transport" == "http" ]]; then
        if [[ -z "${MCP_PANDOC_AUTH_TOKEN:-}" ]]; then
            warn "MCP_PANDOC_AUTH_TOKEN not set, generating a random token for testing"
            export MCP_PANDOC_AUTH_TOKEN="test-token-$(openssl rand -hex 8)"
            warn "Using token: ${MCP_PANDOC_AUTH_TOKEN}"
        fi
        info "Starting MCP server in HTTP mode on port 8080..."
        info "MCP endpoint: http://localhost:8080/mcp"
        info "Upload endpoint: http://localhost:8080/upload"
    else
        info "Starting MCP server in stdio mode..."
    fi

    cd "$SCRIPT_DIR"
    uv run mcp-pandoc
}

cmd_build() {
    info "Building Docker image: ${IMAGE_REPO_TAG}..."
    cd "$SCRIPT_DIR"
    docker build -t "${IMAGE_REPO_TAG}" .
    info "Build complete: ${IMAGE_REPO_TAG}"
}

cmd_test() {
    local base_url="${TEST_BASE_URL:-}"
    local is_remote=false

    if [[ -n "$base_url" ]]; then
        is_remote=true
        info "Testing against remote: ${base_url}"
        local auth_token="${MCP_PANDOC_AUTH_TOKEN:-test-token-123456}"
    else
        info "Running local integration tests..."
        auth_token="test-token-$(openssl rand -hex 8)"
        local test_port=18080
        export MCP_PANDOC_AUTH_TOKEN="$auth_token"
        export MCP_PANDOC_TRANSPORT=http
        export MCP_PANDOC_PORT="$test_port"
        export MCP_PANDOC_UPLOAD_DIR="/tmp/mcp-pandoc-test-uploads"
        export MCP_PANDOC_BASE_URL="http://localhost:${test_port}"
        mkdir -p "$MCP_PANDOC_UPLOAD_DIR"
        base_url="http://localhost:${test_port}"

        info "Starting server in background..."
        cd "$SCRIPT_DIR"
        uv run mcp-pandoc &
        local server_pid=$!
        sleep 3
        trap "kill $server_pid 2>/dev/null; rm -rf $MCP_PANDOC_UPLOAD_DIR" EXIT
    fi

    info "Testing create_upload_session tool..."
    local session_resp
    session_resp=$(curl -s -X POST "${base_url}/mcp" \
        -H "Authorization: Bearer ${auth_token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_upload_session","arguments":{"filename":"README.md"}}}')
    info "Session response: ${session_resp}"

    local upload_url readme_file_id
    read -r upload_url readme_file_id <<< $(echo "$session_resp" | python3 -c "
import sys, json
raw = sys.stdin.read()
data_lines = [line[5:] for line in raw.split('\n') if line.startswith('data: ')]
data_json = ''.join(data_lines)
data = json.loads(data_json)
result = data.get('result', {})
content = json.loads(result.get('content', [{}])[0].get('text', '{}'))
print(content['upload_url'], content['uploaded_file_id'])
")
    info "Got upload_url: ${upload_url}"
    info "Got file_id: ${readme_file_id}"

    info "Uploading README.md to session URL (no auth token needed)..."
    local upload_resp
    upload_resp=$(curl -s -X POST "${upload_url}" -F "file=@${SCRIPT_DIR}/README.md")
    info "Upload response: ${upload_resp}"

    info "Testing MCP convert_contents tool (README.md -> DOCX)..."
    local convert_req
    convert_req=$(cat <<JSONEOF
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"convert_contents","arguments":{"uploaded_file_id":"${readme_file_id}","input_format":"markdown","output_format":"docx","return_download_url":true}}}
JSONEOF
)
    local convert_resp
    convert_resp=$(curl -s -X POST "${base_url}/mcp" \
        -H "Authorization: Bearer ${auth_token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "$convert_req")
    info "Convert response: ${convert_resp}"

    local docx_download_url
    docx_download_url=$(echo "$convert_resp" | python3 -c "
import sys, json, re

raw = sys.stdin.read()
data_lines = [line[5:] for line in raw.split('\n') if line.startswith('data: ')]
if not data_lines:
    print('ERROR: No SSE data lines found')
    sys.exit(1)

data_json = ''.join(data_lines)
data = json.loads(data_json)
result = data.get('result', {})
is_error = result.get('isError', False)
content = result.get('content', [{}])[0].get('text', '')

if is_error:
    print('ERROR: ' + content[:200])
    sys.exit(1)

match = re.search(r'Download:\s*(https?://\S+)', content)
if match:
    print(match.group(1))
else:
    print('ERROR: Could not extract download URL from: ' + content[:100])
")
    if [[ "$docx_download_url" == ERROR:* ]]; then
        error "DOCX conversion failed: ${docx_download_url}"
        exit 1
    fi
    info "Got DOCX download URL: ${docx_download_url}"

    info "Downloading converted DOCX (no auth token needed)..."
    local output_docx="/tmp/mcp-pandoc-test-output.docx"
    curl -s -X GET "${docx_download_url}" -o "$output_docx"
    if [[ -f "$output_docx" ]] && [[ $(stat -c%s "$output_docx" 2>/dev/null || stat -f%z "$output_docx" 2>/dev/null) -gt 0 ]]; then
        info "DOCX downloaded successfully to: ${output_docx}"
        info "DOCX size: $(stat -c%s "$output_docx" 2>/dev/null || stat -f%z "$output_docx" 2>/dev/null) bytes"
    else
        error "DOCX download failed or file is empty"
        exit 1
    fi

    info "Testing PDF conversion (simple content)..."
    local pdf_convert_req
    pdf_convert_req=$(cat <<JSONEOF
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"convert_contents","arguments":{"contents":"# Hello World\\n\\nThis is a simple test for PDF conversion. 中文测试。","input_format":"markdown","output_format":"pdf","return_download_url":true}}}
JSONEOF
)
    local pdf_convert_resp
    pdf_convert_resp=$(curl -s -X POST "${base_url}/mcp" \
        -H "Authorization: Bearer ${auth_token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "$pdf_convert_req")
    info "PDF Convert response: ${pdf_convert_resp}"

    local pdf_download_url
    pdf_download_url=$(echo "$pdf_convert_resp" | python3 -c "
import sys, json, re

raw = sys.stdin.read()
data_lines = [line[5:] for line in raw.split('\n') if line.startswith('data: ')]
if not data_lines:
    print('ERROR: No SSE data lines found')
    sys.exit(1)

data_json = ''.join(data_lines)
data = json.loads(data_json)
result = data.get('result', {})
is_error = result.get('isError', False)
content = result.get('content', [{}])[0].get('text', '')

if is_error:
    print('ERROR: ' + content[:200])
    sys.exit(1)

match = re.search(r'Download:\s*(https?://\S+)', content)
if match:
    print(match.group(1))
else:
    print('ERROR: Could not extract download URL from: ' + content[:100])
")
    if [[ "$pdf_download_url" == ERROR:* ]]; then
        error "PDF conversion failed: ${pdf_download_url}"
        exit 1
    fi
    info "Got PDF download URL: ${pdf_download_url}"

    info "Downloading converted PDF (no auth token needed)..."
    local output_pdf="/tmp/mcp-pandoc-test-output.pdf"
    curl -s -X GET "${pdf_download_url}" -o "$output_pdf"
    if [[ -f "$output_pdf" ]] && [[ $(stat -c%s "$output_pdf" 2>/dev/null || stat -f%z "$output_pdf" 2>/dev/null) -gt 0 ]]; then
        info "PDF downloaded successfully to: ${output_pdf}"
        info "PDF size: $(stat -c%s "$output_pdf" 2>/dev/null || stat -f%z "$output_pdf" 2>/dev/null) bytes"
    else
        error "PDF download failed or file is empty"
        exit 1
    fi

    info "Testing invalid file_id returns 404..."
    local invalid_resp
    invalid_resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${base_url}/upload/nonexistent-file-id" \
        -F "file=@/tmp/test-upload.txt")
    if [[ "$invalid_resp" == "404" ]]; then
        info "Invalid file_id check passed: correctly rejected with 404"
    else
        error "Invalid file_id check failed: expected 404, got ${invalid_resp}"
    fi

    info "All tests passed!"
}

cmd_deploy_fc() {
    if ! command -v s &>/dev/null; then
        error "s tool not found. Install with: npm install -g @serverless-devs/s"
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/s.yaml" ]]; then
        error "s.yaml not found. Copy s.yaml.example to s.yaml and edit with your settings."
        exit 1
    fi

    info "Deploying to Function Compute using s tool..."
    cd "$SCRIPT_DIR"
    s deploy -y

    info "=== Deployment complete ==="
    info "View function: s info"
}

# Main
case "${1:-}" in
    run)       cmd_run "${2:-stdio}" ;;
    build)     cmd_build ;;
    deploy-fc) cmd_deploy_fc ;;
    test)      cmd_test ;;
    *)         usage; exit 1 ;;
esac
