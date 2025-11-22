#!/bin/bash
set -e

# Update system packages
sudo yum update -y

# Install Docker
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Create directories for Docker Compose and n8n data
sudo mkdir -p /opt/n8n
sudo mkdir -p /opt/n8n/docker
sudo mkdir -p /opt/n8n/data
sudo mkdir -p /opt/n8n/postgres-data
sudo mkdir -p /opt/n8n/traefik-data
sudo chown -R ec2-user:ec2-user /opt/n8n

# Copy docker-compose.yml to the instance
# Note: ${DOMAIN_NAME} will be replaced by CDK during stack deployment
cat > /opt/n8n/docker/docker-compose.yml << 'DOCKER_COMPOSE_EOF'
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-n8n}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-n8n}
      POSTGRES_DB: ${POSTGRES_DB:-n8n}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U ${POSTGRES_USER:-n8n}']
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n}
      - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD:-n8n}
      - N8N_HOST=${DOMAIN_NAME}
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=UTC
      - TZ=UTC
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER:-admin}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD:-changeme}
    volumes:
      - n8n_data:/home/node/.n8n
      - ./local-files:/files
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - n8n-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${DOMAIN_NAME}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  traefik:
    image: traefik:v2.11
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN_NAME=${DOMAIN_NAME}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_data:/letsencrypt
    command:
      - --api.dashboard=false
      - --log.level=INFO
      - --accesslog=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.watch=true
      - --entrypoints.web.address=0.0.0.0:80
      - --entrypoints.websecure.address=0.0.0.0:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.http.tls=true
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL:-admin@${DOMAIN_NAME}}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:80/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - n8n-network

volumes:
  postgres_data:
  n8n_data:
  traefik_data:

networks:
  n8n-network:
    driver: bridge
DOCKER_COMPOSE_EOF

# Create .env file for Docker Compose
cat > /opt/n8n/docker/.env << EOF
DOMAIN_NAME=${DOMAIN_NAME}
POSTGRES_USER=n8n
POSTGRES_PASSWORD=\$(openssl rand -base64 32)
POSTGRES_DB=n8n
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=\$(openssl rand -base64 32)
ACME_EMAIL=admin@${DOMAIN_NAME}
EOF

# Set proper permissions
sudo chown -R ec2-user:ec2-user /opt/n8n
chmod 600 /opt/n8n/docker/.env

# Start Docker Compose services
cd /opt/n8n/docker
sudo -u ec2-user docker-compose up -d

# Wait for services to be ready
sleep 30

# Fix permissions for acme.json (Traefik needs to write to it)
# Wait a bit more for Traefik to create the volume and acme.json
sleep 15
# Find the acme.json file in any traefik_data volume
for acme_file in /var/lib/docker/volumes/*traefik*/_data/acme.json; do
    if [ -f "$acme_file" ]; then
        sudo chmod 600 "$acme_file"
        sudo chown root:root "$acme_file"
        echo "Fixed permissions for acme.json: $acme_file"
        break
    fi
done
# Also fix permissions inside the container if it exists
sudo -u ec2-user docker exec traefik chmod 600 /letsencrypt/acme.json 2>/dev/null || true

# Log the initial admin password (in production, use AWS Secrets Manager)
echo "n8n setup completed. Check /opt/n8n/docker/.env for credentials."

# Set up log rotation for Docker containers
sudo tee /etc/logrotate.d/docker-containers > /dev/null << 'LOGROTATE_EOF'
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    size=10M
    missingok
    delaycompress
    copytruncate
}
LOGROTATE_EOF

# Install utilities for health checks
sudo yum install -y bind-utils curl openssl

# Create scripts directory
sudo mkdir -p /opt/n8n/scripts
sudo chown ec2-user:ec2-user /opt/n8n/scripts

# Create check-traefik-local.sh script for monitoring
sudo tee /opt/n8n/scripts/check-traefik-local.sh > /dev/null << 'CHECK_TRAEFIK_LOCAL_EOF'
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
CHECK_TRAEFIK_LOCAL_EOF

# Make the script executable
sudo chmod +x /opt/n8n/scripts/check-traefik-local.sh
sudo chown ec2-user:ec2-user /opt/n8n/scripts/check-traefik-local.sh

# Also create a symlink in /usr/local/bin for easy access
sudo ln -sf /opt/n8n/scripts/check-traefik-local.sh /usr/local/bin/check-traefik-local

echo "check-traefik-local.sh script installed at /opt/n8n/scripts/check-traefik-local.sh"
echo "Also available as: check-traefik-local"

