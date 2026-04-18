#!/bin/bash

# Pear Messaging Backend - AWS Deployment Script
# Similar to previous deployment workflow

set -e

echo "🚀 Starting AWS Deployment for Pear Messaging Backend..."

# Configuration
REPO_NAME="pear-messaging-backend"
AWS_USER="ubuntu"
AWS_IP="YOUR_EC2_PUBLIC_IP"  # Replace with your actual EC2 IP
REMOTE_DIR="/tmp/pear-messaging-backend"

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

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not in a git repository. Initialize git first."
    exit 1
fi

# Step 1: Stage and commit changes
print_status "Staging changes for commit..."
git add .

print_status "Committing changes..."
if git diff --cached --quiet; then
    print_warning "No changes to commit"
else
    git commit -m "Deploy secure image messaging backend - $(date)"
    print_status "Changes committed successfully"
fi

# Step 2: Push to remote repository
print_status "Pushing to remote repository..."
git push origin main 2>/dev/null || git push origin master 2>/dev/null || {
    print_warning "No remote configured or push failed, continuing with deployment..."
}

# Step 3: Deploy to AWS
print_status "Deploying to AWS EC2 instance..."

# Create remote directory and copy files
ssh $AWS_USER@$AWS_IP "mkdir -p $REMOTE_DIR"

# Copy files to AWS
print_status "Copying files to AWS..."
rsync -avz --progress \
    --exclude node_modules \
    --exclude temp_media \
    --exclude logs \
    --exclude .git \
    --exclude deployment-info.txt \
    ./ $AWS_USER@$AWS_IP:$REMOTE_DIR/

# Step 4: Run deployment script on AWS
print_status "Running deployment script on AWS..."
ssh $AWS_USER@$AWS_IP "cd $REMOTE_DIR && chmod +x ec2-deploy.sh && ./ec2-deploy.sh"

# Step 5: Verify deployment
print_status "Verifying deployment..."
sleep 10

# Test health endpoint
if curl -f http://$AWS_IP/health > /dev/null 2>&1; then
    print_status "✅ Backend is running successfully!"
else
    print_error "❌ Backend health check failed"
    exit 1
fi

# Display deployment info
echo ""
echo "🎉 AWS Deployment Complete!"
echo ""
echo "📊 Service Status:"
ssh $AWS_USER@$AWS_IP "pm2 status"
echo ""
echo "🌐 Available Endpoints:"
echo "   Health Check: http://$AWS_IP/health"
echo "   Media Upload: POST http://$AWS_IP/media/upload"
echo "   Media Download: GET http://$AWS_IP/media/download/{token}"
echo ""
echo "🔧 Management Commands:"
echo "   SSH: ssh $AWS_USER@$AWS_IP"
echo "   Logs: ssh $AWS_USER@$AWS_IP 'pm2 logs pear-messaging'"
echo "   Restart: ssh $AWS_USER@$AWS_IP 'pm2 restart pear-messaging'"
echo ""
echo "📱 Update Flutter App:"
echo "   Update baseUrl in lib/core/services/media_service.dart to: http://$AWS_IP"
echo ""

# Save deployment info
cat > deployment-info.txt <<EOF
AWS Deployment Information
========================

Deployment Date: $(date)
AWS Instance: $AWS_IP
Remote User: $AWS_USER
Remote Directory: $REMOTE_DIR

Endpoints:
- Health: http://$AWS_IP/health
- Upload: POST http://$AWS_IP/media/upload
- Download: GET http://$AWS_IP/media/download/{token}

Management:
- SSH: ssh $AWS_USER@$AWS_IP
- Logs: ssh $AWS_USER@$AWS_IP 'pm2 logs pear-messaging'
- Restart: ssh $AWS_USER@$AWS_IP 'pm2 restart pear-messaging'
- Status: ssh $AWS_USER@$AWS_IP 'pm2 status'

Git Commands:
- Commit: git add . && git commit -m "message"
- Push: git push origin main
- Deploy: ./deploy-to-aws.sh
EOF

print_status "Deployment information saved to deployment-info.txt"
