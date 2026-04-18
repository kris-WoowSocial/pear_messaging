#!/bin/bash

# Pear Messaging Backend - Update and Restart Script
# Similar to previous workflow: pull from git and restart server

set -e

echo "🔄 Updating Pear Messaging Backend..."

# Configuration
SERVICE_NAME="pear-messaging"
APP_DIR="/opt/pear-messaging-backend"

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
   print_error "This script should not be run as root"
   exit 1
fi

# Navigate to app directory
cd $APP_DIR

# Step 1: Pull latest changes from git
print_status "Pulling latest changes from git..."
git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || {
    print_warning "Git pull failed or no remote configured, continuing with local changes..."
}

# Step 2: Install/update dependencies
print_status "Installing/updating dependencies..."
npm ci --only=production

# Step 3: Restart the application
print_status "Restarting application..."
pm2 restart $SERVICE_NAME

# Step 4: Wait for restart
sleep 5

# Step 5: Verify application is running
print_status "Verifying application status..."
if pm2 describe $SERVICE_NAME | grep -q "online"; then
    print_status "✅ Application is running successfully!"
else
    print_error "❌ Application failed to start"
    pm2 logs $SERVICE_NAME --lines 20
    exit 1
fi

# Step 6: Health check
print_status "Running health check..."
if curl -f http://localhost:3001/health > /dev/null 2>&1; then
    print_status "✅ Health check passed"
else
    print_error "❌ Health check failed"
    pm2 logs $SERVICE_NAME --lines 10
    exit 1
fi

# Display status
echo ""
echo "📊 Current Status:"
pm2 status
echo ""
echo "🌐 Application Endpoints:"
echo "   Health Check: http://localhost/health"
echo "   Media Upload: POST http://localhost/media/upload"
echo "   Media Download: GET http://localhost/media/download/{token}"
echo ""
echo "📝 Recent Logs:"
pm2 logs $SERVICE_NAME --lines 10
echo ""

print_status "Update and restart completed successfully!"
