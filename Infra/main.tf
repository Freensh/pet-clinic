terraform {
  required_providers {
    aws = { 
      source  = "hashicorp/aws" 
      version = "~> 5.3.0" 
    }
  }
}

provider "aws" { region = "us-east-1" }

# Data Sources: Fetch Default VPC and Subnets dynamically
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 1. ECS Task Execution Role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "resume_ecs_task_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# 2. ECR Repository
resource "aws_ecr_repository" "resume_repo" {
  name                 = "petclinic"
  image_tag_mutability = "MUTABLE"
}

# 3. Security Groups
# NEW: ALB Security Group to allow public HTTP traffic
resource "aws_security_group" "alb_sg" {
  name   = "petclinic-alb-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# UPDATED: ECS SG now only accepts traffic from the ALB Security Group
resource "aws_security_group" "ecs_sg" {
  name   = "petclinic-ecs-sg"
  vpc_id = data.aws_vpc.default.id
  
  ingress { 
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp" 
    security_groups = [aws_security_group.alb_sg.id] 
  }
  
  egress { 
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] 
  }
}

# 4. Load Balancer Resources (NEW)
resource "aws_lb" "app_alb" {
  name               = "petclinic-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app_tg" {
  name        = "petclinic-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-299"
  }
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# 5. ECS Cluster & Task Definition
resource "aws_ecs_cluster" "resume_cluster" {
  name = "petclinic-cluster"
}

resource "aws_ecs_task_definition" "resume_task" {
  family                   = "petclinic-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name      = "petclinic-app", 
    image     = "nginx:alpine", 
    essential = true,
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
  }])
}

# 6. ECS Service (UPDATED to use Load Balancer)
resource "aws_ecs_service" "resume_service" {
  name            = "portfolio-service"
  cluster         = aws_ecs_cluster.resume_cluster.id
  task_definition = aws_ecs_task_definition.resume_task.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }

  # NEW: Connect the ECS service to the ALB Target Group
  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "petclinic-app" 
    container_port   = 8080            
  }

  lifecycle {
    ignore_changes = [task_definition] 
  }

  # NEW: Ensure the ALB listener is created before the ECS service tries to register targets
  depends_on = [aws_lb_listener.app_listener]
}

# Optional: Output the ALB DNS name so you can easily click it after applying
output "alb_dns_name" {
  value       = aws_lb.app_alb.dns_name
  description = "The DNS name of the Application Load Balancer"
}