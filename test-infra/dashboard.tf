resource "aws_cloudwatch_dashboard" "loadtest" {
  dashboard_name = "${var.name_prefix}-dashboard"

  # Leave start/end unset so the CloudWatch dashboard time selector controls
  # every metrics and Logs Insights widget, including a custom test window.
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title  = "Host CPU used (CloudWatch Agent, 1-minute)"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["CWAgent", "used_percent", "InstanceId", aws_instance.app.id, "InstanceType", aws_instance.app.instance_type, "cpu", "cpu-total", { label = "App EC2" }],
            ["CWAgent", "used_percent", "InstanceId", aws_instance.k6.id, "InstanceType", aws_instance.k6.instance_type, "cpu", "cpu-total", { label = "k6 EC2" }],
          ]
          yAxis = {
            left = {
              min   = 0
              max   = 100
              label = "Percent"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          region = var.aws_region
          title  = "EC2 memory used"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["CWAgent", "mem_used_percent", "InstanceId", aws_instance.app.id, "InstanceType", aws_instance.app.instance_type, { label = "App EC2" }],
            ["CWAgent", "mem_used_percent", "InstanceId", aws_instance.k6.id, "InstanceType", aws_instance.k6.instance_type, { label = "k6 EC2" }],
          ]
          yAxis = {
            left = {
              min   = 0
              max   = 100
              label = "Percent"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          region = var.aws_region
          title  = "EC2 network traffic (5-minute CloudWatch metrics)"
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.app.id, { label = "App inbound" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.app.id, { label = "App outbound" }],
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.k6.id, { label = "k6 inbound" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.k6.id, { label = "k6 outbound" }],
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 12
        height = 8
        properties = {
          region = var.aws_region
          title  = "Application container logs"
          view   = "table"
          query  = "SOURCE '/stockspoon/app/containers/nginx' | SOURCE '/stockspoon/app/containers/frontend' | SOURCE '/stockspoon/app/containers/backend' | SOURCE '/stockspoon/app/containers/db' | fields @timestamp, @logStream, @message\n| sort @timestamp desc\n| limit 100"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 12
        width  = 12
        height = 8
        properties = {
          region = var.aws_region
          title  = "Load-test host and CloudWatch Agent logs"
          view   = "table"
          query  = "SOURCE '/stockspoon/loadtest/system' | fields @timestamp, @logStream, @message\n| sort @timestamp desc\n| limit 100"
        }
      },
    ]
  })
}

output "loadtest_dashboard_name" {
  description = "CloudWatch dashboard for the load-test EC2 instances"
  value       = aws_cloudwatch_dashboard.loadtest.dashboard_name
}
