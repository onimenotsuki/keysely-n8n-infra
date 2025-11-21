#!/bin/bash
# Script to verify Traefik configuration (runs locally on EC2 instance)
# Usage: ./check-traefik-local.sh [domain-name]

set -e

DOMAIN="${1:-n8n.keysely.com}"

echo "=========================================="
echo "Traefik Configuration Check"
echo "=========================================="
echo "Domain: ${DOMAIN}"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_passed() {
    echo -e "${GREEN}✓${NC} $1"
}

check_failed() {
    echo -e "${RED}✗${NC} $1"
}

check_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

echo "1. Checking Docker containers status..."
echo "----------------------------------------"
cd /opt/n8n/docker 2>/dev/null || { check_failed "Cannot access /opt/n8n/docker"; exit 1; }
echo "Container Status:"
if command -v docker-compose &> /dev/null; then
    docker-compose ps
else
    docker compose ps
fi
echo ""
echo "Container Health:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "2. Checking Traefik logs..."
echo "----------------------------------------"
echo "Last 50 lines of Traefik logs:"
docker logs traefik --tail 50 2>/dev/null || check_failed "Cannot access Traefik logs"
echo ""

echo "3. Checking Traefik configuration..."
echo "----------------------------------------"
echo "Traefik container environment variables:"
docker inspect traefik 2>/dev/null | grep -A 30 '"Env"' | head -20 || docker inspect traefik | grep -A 20 "Env"
echo ""
echo "Traefik labels on n8n service:"
if command -v jq &> /dev/null; then
    docker inspect n8n 2>/dev/null | jq '.[0].Config.Labels' | grep traefik || check_warning "No Traefik labels found or jq not available"
else
    docker inspect n8n 2>/dev/null | grep -A 10 "traefik" || check_warning "No Traefik labels found"
fi
echo ""

echo "4. Checking Let's Encrypt certificates..."
echo "----------------------------------------"
echo "Checking acme.json file:"
if docker exec traefik ls -la /letsencrypt/ 2>/dev/null; then
    ACME_SIZE=$(docker exec traefik stat -c%s /letsencrypt/acme.json 2>/dev/null || echo "0")
    if [ "$ACME_SIZE" -gt 0 ]; then
        check_passed "acme.json exists and has content (${ACME_SIZE} bytes)"
    else
        check_warning "acme.json exists but is empty (certificate may still be provisioning)"
    fi
else
    check_failed "Cannot access /letsencrypt directory"
fi
echo ""

echo "5. Checking DNS resolution..."
echo "----------------------------------------"
if command -v dig &> /dev/null; then
    DNS_IP=$(dig +short ${DOMAIN} | tail -n1)
    if [ -n "$DNS_IP" ]; then
        check_passed "DNS resolves ${DOMAIN} to ${DNS_IP}"
        # Get instance public IP
        INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
        if [ -n "$INSTANCE_IP" ] && [ "$DNS_IP" = "$INSTANCE_IP" ]; then
            check_passed "DNS IP matches instance public IP"
        elif [ -n "$INSTANCE_IP" ]; then
            check_warning "DNS IP (${DNS_IP}) does not match instance IP (${INSTANCE_IP})"
        fi
    else
        check_failed "DNS does not resolve for ${DOMAIN}"
    fi
else
    check_warning "dig command not found. Install bind-utils to check DNS"
    echo "  Manual check: dig ${DOMAIN} or nslookup ${DOMAIN}"
fi
echo ""

echo "6. Checking HTTP connectivity..."
echo "----------------------------------------"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://${DOMAIN} 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "308" ]; then
    check_passed "HTTP redirects to HTTPS (code: ${HTTP_CODE})"
elif [ "$HTTP_CODE" = "000" ]; then
    check_failed "Cannot connect to http://${DOMAIN}"
else
    check_warning "HTTP returned code ${HTTP_CODE} (expected 301/302/308 redirect)"
fi
echo ""

echo "7. Checking HTTPS connectivity and SSL certificate..."
echo "----------------------------------------"
if command -v openssl &> /dev/null; then
    echo "Testing SSL certificate:"
    SSL_INFO=$(echo | timeout 5 openssl s_client -servername ${DOMAIN} -connect ${DOMAIN}:443 -showcerts 2>/dev/null | openssl x509 -noout -dates -subject -issuer 2>/dev/null)
    if [ -n "$SSL_INFO" ]; then
        check_passed "SSL certificate is valid"
        echo "$SSL_INFO" | while IFS= read -r line; do
            echo "  $line"
        done
    else
        check_warning "Cannot retrieve SSL certificate (may still be provisioning)"
    fi
else
    check_warning "openssl not found. Install openssl to check SSL certificate"
fi

HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://${DOMAIN} 2>/dev/null || echo "000")
if [ "$HTTPS_CODE" = "401" ]; then
    check_passed "HTTPS is accessible (401 = Basic Auth required, which is correct)"
elif [ "$HTTPS_CODE" = "200" ]; then
    check_passed "HTTPS is accessible"
elif [ "$HTTPS_CODE" = "000" ]; then
    check_failed "Cannot connect to https://${DOMAIN}"
else
    check_warning "HTTPS returned code ${HTTPS_CODE}"
fi
echo ""

echo "8. Checking Traefik routing configuration..."
echo "----------------------------------------"
echo "Checking if n8n service is discoverable by Traefik:"
NETWORK_NAME=$(docker inspect n8n 2>/dev/null | grep -oP '"Networks":\s*"\K[^"]+' | head -1 || echo "n8n-docker_n8n-network")
if docker network inspect ${NETWORK_NAME} 2>/dev/null | grep -q "n8n"; then
    check_passed "n8n is in the Docker network"
else
    check_warning "Cannot verify n8n network configuration"
fi
echo ""
echo "Testing internal connectivity from Traefik to n8n:"
if docker exec traefik wget -qO- http://n8n:5678/healthz 2>/dev/null; then
    check_passed "n8n is reachable from Traefik container"
else
    # Try alternative health check endpoint
    if docker exec traefik wget -qO- http://n8n:5678/ 2>/dev/null | grep -q "n8n"; then
        check_passed "n8n is reachable from Traefik (alternative check)"
    else
        check_warning "n8n may not be reachable from Traefik (check logs)"
    fi
fi
echo ""

echo "9. Checking port bindings..."
echo "----------------------------------------"
echo "Ports listening on the host:"
if command -v ss &> /dev/null; then
    sudo ss -tlnp | grep -E ':(80|443)' || check_warning "Ports 80/443 not found in ss output"
else
    sudo netstat -tlnp 2>/dev/null | grep -E ':(80|443)' || check_warning "Ports 80/443 not found in netstat output"
fi
echo ""
echo "Docker port mappings:"
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -E "(traefik|80|443)"
echo ""

echo "10. Checking Traefik service discovery..."
echo "----------------------------------------"
echo "Services discovered by Traefik:"
# Try to access Traefik API if enabled (though it's disabled in our config)
# Instead, check if Traefik can see the n8n container
if docker exec traefik cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep -q "DOCKER_HOST"; then
    check_passed "Traefik has access to Docker socket"
else
    check_warning "Cannot verify Docker socket access"
fi
echo ""

echo "11. Summary and recommendations..."
echo "----------------------------------------"
echo ""
echo "Expected Traefik configuration:"
echo "  ✓ Traefik container running on ports 80 and 443"
echo "  ✓ Let's Encrypt certificate resolver configured"
echo "  ✓ HTTP to HTTPS redirect enabled"
echo "  ✓ n8n service with Traefik labels"
echo "  ✓ DNS pointing to instance IP"
echo "  ✓ SSL certificate valid and working"
echo ""
echo "If any checks failed:"
echo "  1. Check Traefik logs: docker logs traefik"
echo "  2. Check n8n logs: docker logs n8n"
echo "  3. Verify DNS is configured correctly"
echo "  4. Ensure security groups allow ports 80 and 443"
echo "  5. Check that Let's Encrypt can reach port 80 (for HTTP challenge)"
echo "  6. Wait a few minutes for certificate provisioning (first time)"
echo "  7. Restart services if needed: cd /opt/n8n/docker && docker-compose restart"
echo ""

