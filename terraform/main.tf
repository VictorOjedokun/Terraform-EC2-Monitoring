terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "key_name" {
  description = "Your SSH key pair name"
  type        = string
}

# Get latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Security Group
resource "aws_security_group" "app_sg" {
  name        = "flask-app-sg"
  description = "Security group for Flask app with monitoring"

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Flask app
  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Prometheus
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instance
resource "aws_instance" "app" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.small"
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.app_sg.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

   user_data = <<-EOF
              #!/bin/bash
              set -e
              exec > >(tee /var/log/user-data.log)
              exec 2>&1

              echo "Starting setup..."

              # Update system
              apt-get update
              apt-get upgrade -y

              # Install Python and dependencies
              apt-get install -y python3 python3-pip python3-venv wget curl git

              # Create app directory
              mkdir -p /opt/flask-app
              cd /opt/flask-app

              # Create virtual environment
              python3 -m venv venv

              # Install Prometheus
              echo "Installing Prometheus..."
              cd /tmp
              wget https://github.com/prometheus/prometheus/releases/download/v2.48.0/prometheus-2.48.0.linux-amd64.tar.gz
              tar xvfz prometheus-2.48.0.linux-amd64.tar.gz
              mv prometheus-2.48.0.linux-amd64 /opt/prometheus
              
              # Create Prometheus config
              cat > /opt/prometheus/prometheus.yml <<'PROM'
              global:
                scrape_interval: 15s

              scrape_configs:
                - job_name: 'prometheus'
                  static_configs:
                    - targets: ['localhost:9090']

                - job_name: 'flask-app'
                  static_configs:
                    - targets: ['localhost:5000']
                  metrics_path: '/metrics'
              PROM

              # Create Prometheus systemd service
              cat > /etc/systemd/system/prometheus.service <<'PROMSVC'
              [Unit]
              Description=Prometheus
              After=network.target

              [Service]
              Type=simple
              User=root
              ExecStart=/opt/prometheus/prometheus --config.file=/opt/prometheus/prometheus.yml --storage.tsdb.path=/opt/prometheus/data
              Restart=always

              [Install]
              WantedBy=multi-user.target
              PROMSVC

              # Install Grafana
              echo "Installing Grafana..."
              apt-get install -y apt-transport-https software-properties-common
              wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
              echo "deb https://packages.grafana.com/oss/deb stable main" | tee /etc/apt/sources.list.d/grafana.list
              apt-get update
              apt-get install -y grafana

              # Configure Grafana datasource
              mkdir -p /etc/grafana/provisioning/datasources
              cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'GRAF'
              apiVersion: 1
              datasources:
                - name: Prometheus
                  type: prometheus
                  access: proxy
                  url: http://localhost:9090
                  isDefault: true
              GRAF

              # Create Flask systemd service
              cat > /etc/systemd/system/flask-app.service <<'FLASKSVC'
              [Unit]
              Description=Flask Application
              After=network.target

              [Service]
              Type=simple
              User=root
              WorkingDirectory=/opt/flask-app
              Environment="PATH=/opt/flask-app/venv/bin"
              ExecStart=/opt/flask-app/venv/bin/gunicorn --bind 0.0.0.0:5000 --workers 2 app:app
              Restart=always

              [Install]
              WantedBy=multi-user.target
              FLASKSVC

              # Set permissions for deployment
              chown -R ubuntu:ubuntu /opt/flask-app

              # Start monitoring services
              systemctl daemon-reload
              systemctl enable prometheus
              systemctl start prometheus
              systemctl enable grafana-server
              systemctl start grafana-server

              echo "Setup complete! Ready for GitHub Actions deployment."
              EOF
  tags = {
    Name = "flask-app-instance"
  }
}

# Outputs
output "instance_ip" {
  value = aws_instance.app.public_ip
  description = "Public IP of your EC2 instance"
}

output "ssh_command" {
  value = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.app.public_ip}"
}

output "flask_app_url" {
  value = "http://${aws_instance.app.public_ip}:5000"
}

output "grafana_url" {
  value = "http://${aws_instance.app.public_ip}:3000 (admin/admin)"
}

output "prometheus_url" {
  value = "http://${aws_instance.app.public_ip}:9090"
}

