locals {
  app_cloudwatch_dashboard_metric_searches = {
    cpu_active_total      = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" cpu=\"cpu-total\" MetricName=\"cpu_usage_active\"', 'Average')"
    cpu_iowait_total      = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" cpu=\"cpu-total\" MetricName=\"cpu_usage_iowait\"', 'Average')"
    processes_running     = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"processes_running\"', 'Maximum')"
    storage_device_errors = "SEARCH('{Stockspoon/USE} MetricName=\"StorageDeviceErrorCount\"', 'Sum')"

    memory_used = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"mem_used_percent\"', 'Average')"
    disk_used   = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"disk_used_percent\"', 'Average')"

    diskio_io_time         = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"diskio_io_time\"', 'Sum')"
    diskio_iops_inprogress = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"diskio_iops_in_progress\"', 'Maximum')"

    net_bytes_sent = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"net_bytes_sent\"', 'Sum')"
    net_bytes_recv = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"net_bytes_recv\"', 'Sum')"
    net_drop_in    = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"net_drop_in\"', 'Sum')"
    net_drop_out   = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"net_drop_out\"', 'Sum')"
    net_err_in     = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"net_err_in\"', 'Sum')"
    net_err_out    = "SEARCH('{CWAgent} InstanceId=\"${aws_instance.app.id}\" MetricName=\"net_err_out\"', 'Sum')"
  }
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "stockspoon-v1-app-use"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# Stockspoon V1 · EC2 USE\n호스트 전체 지표입니다. CPU·메모리·디스크·네트워크 추세를 보고 병목 후보를 좁힙니다. FE/BE 컨테이너별 지표는 포함하지 않습니다."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 4
        properties = {
          title     = "CPU active · all cores"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = 60
          metrics   = [[{ expression = local.app_cloudwatch_dashboard_metric_searches.cpu_active_total, id = "cpuactive" }]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 4
        properties = {
          title     = "Memory used"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = 60
          metrics   = [[{ expression = local.app_cloudwatch_dashboard_metric_searches.memory_used, id = "memused" }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 4
        properties = {
          title     = "Root filesystem used"
          view      = "singleValue"
          sparkline = true
          region    = var.aws_region
          period    = 60
          metrics   = [[{ expression = local.app_cloudwatch_dashboard_metric_searches.disk_used, id = "diskused" }]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Runnable processes · proxy"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.processes_running, id = "processesrunning" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Disk I/O time · use pressure signal"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.diskio_io_time, id = "diskiotime" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title   = "Disk I/O requests in progress"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.diskio_iops_inprogress, id = "diskiops" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "CPU I/O wait"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.cpu_iowait_total, id = "cpuiowait" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Storage device errors · host logs"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.storage_device_errors, id = "storageerrors" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Network bytes sent and received"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.net_bytes_sent, id = "netbytessent" }],
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.net_bytes_recv, id = "netbytesrecv" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Network drops and errors"
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
          metrics = [
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.net_drop_in, id = "netdropin" }],
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.net_drop_out, id = "netdropout" }],
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.net_err_in, id = "neterrin" }],
            [{ expression = local.app_cloudwatch_dashboard_metric_searches.net_err_out, id = "neterrout" }]
          ]
        }
      },
      {
        type   = "text"
        x      = 0
        y      = 24
        width  = 24
        height = 4
        properties = {
          markdown = "## Reading the signals\n- CPU active: host compute use; sustained runnable-process growth alongside high CPU active is a CPU contention proxy, not an exact scheduler queue length.\n- CPU I/O wait rising with disk I/O time or in-progress requests suggests storage wait; confirm the signals together.\n- Memory used: sustained values near the alarm threshold warrant checking process memory and swap with Linux tools.\n- Storage error count comes from system journal logs and common I/O error patterns.\n- Network bytes show traffic; drops/errors should normally stay near zero."
        }
      },
    ]
  })
}
