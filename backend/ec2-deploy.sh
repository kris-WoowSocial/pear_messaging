#!/bin/bash

# Pear Messaging Backend EC2 Deployment Script
set -e

echo "🚀 Starting Pear Messaging Backend EC2 Deployment..."

# Configuration
APP_NAME="pear-messaging-backend"
APP_DIR="/opt/$APP_NAME"
SERVICE_NAME="pear-messaging"
NGINX_CONFIG="/etc/nginx/sites-available/$APP_NAME"
REDIS_PASSWORD=${REDIS_PASSWORD:-$(openssl rand -base64 32)}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root for security reasons"
   exit 1
fi

# Update system packages
print_status "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install Node.js 18
print_status "Installing Node.js 18..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Install Redis
print_status "Installing Redis..."
if ! command -v redis-server &> /dev/null; then
    sudo apt install -y redis-server
fi

# Install Nginx
print_status "Installing Nginx..."
if ! command -v nginx &> /dev/null; then
    sudo apt install -y nginx
fi

# Install PM2 for process management
print_status "Installing PM2..."
if ! command -v pm2 &> /dev/null; then
    sudo npm install -g pm2
fi

# Create application directory
print_status "Creating application directory..."
sudo mkdir -p $APP_DIR
sudo chown $USER:$USER $APP_DIR

# Copy application files
print_status "Copying application files..."
cp -r . $APP_DIR/
cd $APP_DIR

# Install dependencies
print_status "Installing Node.js dependencies..."
npm ci --only=production

# Create temp media directory
mkdir -p temp_media
chmod 755 temp_media

# Configure Redis
print_status "Configuring Redis..."
sudo tee /etc/redis/redis.conf > /dev/null <<EOF
bind 127.0.0.1
port 6379
requirepass $REDIS_PASSWORD
maxmemory 256mb
maxmemory-policy allkeys-lru
save ""
appendonly no
EOF

# Start and enable Redis
sudo systemctl restart redis-server
sudo systemctl enable redis-server

# Create environment file
print_status "Creating environment configuration..."
cat > .env <<EOF
NODE_ENV=production
PORT=3001
REDIS_URL=redis://localhost:6379
REDIS_PASSWORD=$REDIS_PASSWORD
ALLOWED_ORIGINS=*
MEDIA_TTL_DAYS=7
MAX_FILE_SIZE_MB=10
TEMP_STORAGE_PATH=./temp_media
UPLOAD_RATE_LIMIT=5
DOWNLOAD_RATE_LIMIT=20
GLOBAL_RATE_LIMIT=1000
LOG_LEVEL=info
DISABLE_ACCESS_LOGS=true
HELMET_ENABLED=true
CORS_ENABLED=true
EOF

# Create PM2 ecosystem file
print_status "Creating PM2 configuration..."
cat > ecosystem.config.js <<EOF
module.exports = {
  apps: [{
    name: '$SERVICE_NAME',
    script: 'server.js',
    instances: 'max',
    exec_mode: 'cluster',
    env: {
      NODE_ENV: 'production',
      PORT: 3001
    },
    error_file: './logs/err.log',
    out_file: './logs/out.log',
    log_file: './logs/combined.log',
    time: true,
    max_memory_restart: '1G',
    node_args: '--max-old-space-size=1024'
  }]
};
EOF

# Create logs directory
mkdir -p logs

# Configure Nginx
print_status "Configuring Nginx..."
sudo tee $NGINX_CONFIG > /dev/null <<EOF
server {
    listen 80;
    server_name _;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone \$binary_remote_addr zone=media:10m rate=5r/s;

    # Health check endpoint
    location /health {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # Media upload endpoint with stricter rate limiting
    location /media/upload {
        limit_req zone=media burst=3 nodelay;
        client_max_body_size 10M;
        
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Timeout settings for large uploads
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Media download endpoint
    location /media/download {
        limit_req zone=api burst=10 nodelay;
        
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }

    # All other API endpoints
    location / {
        limit_req zone=api burst=20 nodelay;
        
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

# Enable Nginx site
sudo ln -sf $NGINX_CONFIG /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
sudo nginx -t

# Start services
print_status "Starting services..."

# Start Redis
sudo systemctl restart redis-server

# Start application with PM2
pm2 delete $SERVICE_NAME 2>/dev/null || true
pm2 start ecosystem.config.js
pm2 save
pm2 startup

# Start Nginx
sudo systemctl restart nginx
sudo systemctl enable nginx

# Configure firewall
print_status "Configuring firewall..."
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# Wait for services to start
sleep 5

# Health checks
print_status "Running health checks..."

# Check Redis
if redis-cli -a "$REDIS_PASSWORD" ping | grep -q PONG; then
    print_status "Redis is healthy"
else
    print_error "Redis health check failed"
    exit 1
fi

# Check application
if curl -f http://localhost:3001/health > /dev/null 2>&1; then
    print_status "Application is healthy"
else
    print_error "Application health check failed"
    pm2 logs $SERVICE_NAME --lines 20
    exit 1
fi

# Check Nginx
if curl -f http://localhost/health > /dev/null 2>&1; then
    print_status "Nginx proxy is healthy"
else
    print_error "Nginx proxy health check failed"
    sudo nginx -t
    exit 1
fi

# Get EC2 public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "localhost")

# Display deployment summary
echo ""
echo "🎉 Deployment Complete!"
echo ""
echo "📊 Service Status:"
pm2 status
echo ""
echo "🌐 Available Endpoints:"
echo "   Health Check: http://$PUBLIC_IP/health"
echo "   Media Upload: POST http://$PUBLIC_IP/media/upload"
echo "   Media Download: GET http://$PUBLIC_IP/media/download/{token}"
echo ""
echo "🔒 Security Configuration:"
echo "   Redis Password: $REDIS_PASSWORD"
echo "   Firewall: Enabled (ports 22, 80, 443)"
echo "   Rate Limiting: Active"
echo "   Security Headers: Enabled"
echo ""
echo "📝 Management Commands:"
echo "   View logs: pm2 logs $SERVICE_NAME"
echo "   Restart app: pm2 restart $SERVICE_NAME"
echo "   Stop app: pm2 stop $SERVICE_NAME"
echo "   Nginx status: sudo systemctl status nginx"
echo "   Redis status: sudo systemctl status redis-server"
echo ""
echo "🔧 Configuration Files:"
echo "   App Directory: $APP_DIR"
echo "   Environment: $APP_DIR/.env"
echo "   PM2 Config: $APP_DIR/ecosystem.config.js"
echo "   Nginx Config: $NGINX_CONFIG"
echo ""

# Save deployment info
cat > deployment-info.txt <<EOF
Pear Messaging Backend Deployment Information
============================================

Deployment Date: $(date)
Public IP: $PUBLIC_IP
Redis Password: $REDIS_PASSWORD

Endpoints:
- Health: http://$PUBLIC_IP/health
- Upload: POST http://$PUBLIC_IP/media/upload
- Download: GET http://$PUBLIC_IP/media/download/{token}

Management:
- Logs: pm2 logs $SERVICE_NAME
- Restart: pm2 restart $SERVICE_NAME
- Status: pm2 status

Security:
- Firewall enabled
- Rate limiting active
- Redis password protected
- Security headers configured
EOF

print_status "Deployment information saved to deployment-info.txt"
print_status "Update your Flutter app baseUrl to: http://$PUBLIC_IP"

echo ""
