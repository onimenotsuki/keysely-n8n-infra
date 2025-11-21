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
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL:-admin@${DOMAIN_NAME}}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
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

