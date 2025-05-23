#!/bin/bash

set -e  # Exit on error

echo "🚀 Setting up Transcription Runner..."

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo "❌ Python 3 not found. Please install Python 3 before proceeding."
    exit 1
fi

# Check if pip is installed
if ! command -v pip3 &> /dev/null; then
    echo "❌ pip3 not found. Please install pip3 before proceeding."
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "⚠️ AWS CLI not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install awscli
        else
            echo "❌ Homebrew not found. Please install AWS CLI manually."
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y awscli
        elif command -v yum &> /dev/null; then
            sudo yum install -y awscli
        else
            echo "❌ Unable to detect package manager. Please install AWS CLI manually."
            exit 1
        fi
    else
        echo "❌ Unsupported OS. Please install AWS CLI manually."
        exit 1
    fi
fi

# Check if netcat is installed
if ! command -v nc &> /dev/null; then
    echo "⚠️ netcat not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install netcat
        else
            echo "❌ Homebrew not found. Please install netcat manually."
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            sudo apt-get update
            sudo apt-get install -y netcat
        elif command -v yum &> /dev/null; then
            sudo yum install -y netcat
        else
            echo "❌ Unable to detect package manager. Please install netcat manually."
            exit 1
        fi
    else
        echo "❌ Unsupported OS. Please install netcat manually."
        exit 1
    fi
fi

# Create virtual environment
echo "🔨 Creating Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

# Install dependencies
echo "📦 Installing dependencies..."
pip install -r requirements.txt

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    echo "📝 Creating .env file from template..."
    cp .env.sample .env
    echo "ℹ️ Please edit the .env file with your configuration before running the scripts."
fi

# Make shell scripts executable
echo "🔑 Making scripts executable..."
chmod +x whisper_parallel.sh

# Set up AWS credentials if needed
if ! aws configure list &> /dev/null; then
    echo "⚠️ AWS credentials not configured. Setting up..."
    echo "Please enter your AWS credentials:"
    aws configure
fi

# Check if AWS key pair exists
KEY_NAME=$(grep KEY_NAME .env | cut -d '=' -f2 || echo "whisper-key")
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" &> /dev/null; then
    echo "🔑 Creating EC2 key pair..."
    mkdir -p ~/.ssh
    aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > ~/.ssh/"$KEY_NAME".pem
    chmod 400 ~/.ssh/"$KEY_NAME".pem
    echo "✅ Key pair created: ~/.ssh/$KEY_NAME.pem"
fi

echo "✅ Setup complete! You can now run ./whisper_parallel.sh"
echo "ℹ️ Remember to edit the .env file with your configuration."