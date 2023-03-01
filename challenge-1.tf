#Custom VPC
resource "google_compute_network" "vpc-flask" {
  name                    = "vpc-flask"
  auto_create_subnetworks = false
}

#Custom Subnet
resource "google_compute_subnetwork" "flask-subnet" {
  name          = "flask-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = "us-central1"
  network       = google_compute_network.vpc-flask.id
}

#Cloud Router
resource "google_compute_router" "falsk_nat_router" {
  name    = "falsk-nat-router"
  region  = google_compute_subnetwork.flask-subnet.region
  network = google_compute_network.vpc-flask.id
}

#Cloud NAT
resource "google_compute_router_nat" "nat" {
  name                               = "flask-nat"
  router                             = google_compute_router.falsk_nat_router.name
  region                             = google_compute_router.falsk_nat_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "All subnets' primary and secondary IP ranges"
}

#VPC Private IP address range
resource "google_compute_global_address" "vpc_flask_ip_range" {
  address       = "10.83.176.0"
  address_type  = "INTERNAL"
  name          = "vpc-flask-ip-range"
  network       = "google_compute_network.vpc-flask.id"
  prefix_length = 20
  purpose       = "VPC_PEERING"
}

#Cloud SQL Service connection method
resource "google_service_networking_connection" "default" {
  network                 = google_compute_network.vpc-flask.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.vpc_flask_ip_range.name]
}

#Cloud SQL instance
resource "google_sql_database_instance" "flask_sql" {
  database_version = "MYSQL_8_0_26"
  name             = "flask-sql"
  region           = "us-central1"
  settings {
    tier = "db-custom-2-7680"
    activation_policy = "ALWAYS"
    availability_type = "REGIONAL"
    backup_configuration {
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
      binary_log_enabled             = true
      enabled                        = true
      location                       = "us"
      start_time                     = "11:00"
      transaction_log_retention_days = 7
    }
    disk_autoresize       = true
    disk_autoresize_limit = 0
    disk_size             = 100
    disk_type             = "PD_SSD"
    ip_configuration {
      authorized_networks {
        value = "34.120.101.158"
      }
      ipv4_enabled    = false
      private_network = "google_compute_network.vpc-flask.id"
    }
    location_preference {
      zone = "us-central1-f"
    }
  }
}

#Firewall for to connect to the Cloud SQL
resource "google_compute_firewall" "allow_db" {
  allow {
    ports    = ["3306"]
    protocol = "tcp"
  }
  direction     = "INGRESS"
  name          = "allow-db"
  network       = "google_compute_network.vpc-flask.id"
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
}

#Firewall Policies for HTTP(S)
resource "google_compute_firewall" "allow_proxy" {
  name = "fw-allow-proxies"
  allow {
    ports    = ["443"]
    protocol = "tcp"
  }
  allow {
    ports    = ["80"]
    protocol = "tcp"
  }
  allow {
    ports    = ["8080"]
    protocol = "tcp"
  }
  direction     = "INGRESS"
  network       = google_compute_network.vpc-flask.id
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
  tags = ["http-server", "https-server"]
}

#Static IP for LB
resource "google_compute_address" "static-external" {
  name         = "static-external"
  address_type = "EXTERNAL"
  network_tier = "STANDARD"
  region       = "us-central1"
}

#Instance template for the instance group
resource "google_compute_instance_template" "flask_app_template" {
  disk {
    auto_delete  = true
    boot         = true
    device_name  = "flask-app-template"
    disk_size_gb = 20
    disk_type    = "pd-balanced"
    mode         = "READ_WRITE"
    source_image = "debian-cloud/debian-11"
    type         = "PERSISTENT"
  }
  machine_type = "e2-medium"
  name         = "flask-app-template"
  network_interface {
    network            = ""google_compute_network.vpc-flask.id""
    stack_type         = "IPV4_ONLY"
    subnetwork         = "google_compute_subnetwork.flask-subnet.id"
  }
  metadata_startup_script = "pip install flask; pip install wheel; pip install gunicorn flask; sudo apt-get install python3-mysqldb; sudo   apt install git -y; cd /home; sudo git clone https://github.com/operator670/blogapp.git; cd /home/blogapp/blogapp; sudo python3           __init__.py"
 
  region  = "us-central1"
  reservation_affinity {
    type = "ANY_RESERVATION"
  }
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }
  service_account {
    email  = "878425980302-compute@developer.gserviceaccount.com"
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  tags = ["http-server", "https-server"]
}

#Autoscaling
resource "google_compute_autoscaler" "default" {
  provider = google-beta
  region   = "us-central1"
  target   = google_compute_instance_group_manager.flask-app-mig.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 60
   
    cpu_utilization {
      target = 0.5
    }
  }
}

#Instance Group
resource "google_compute_instance_group_manager" "flask-app-mig" {
  name = "flask-app-mig"
  zone = "us-central1-f"

  version {
    instance_template = google_compute_instance_template.flask_app_template.id
  }
  named_port {
    name = "customhttp"
    port = 8888
  }
}

#LB Health check
resource "google_compute_health_check" "flask_app_hc" {
  check_interval_sec = 5
  healthy_threshold  = 2
  log_config {
    enable = true
  }
  name    = "flask-app-hc"
  tcp_health_check {
    port         = 80
    proxy_header = "NONE"
  }
  timeout_sec         = 5
  unhealthy_threshold = 2
}

#LB Backend Service
resource "google_compute_backend_service" "flask_backend" {
  name                  = "flask_backend"
  region                = "us-central1"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_region_health_check.flask_app_hc.id]
  protocol              = "HTTP"
  session_affinity      = "NONE"
  timeout_sec           = 30
  backend {
    group           = google_compute_instance_group_manager.flask-app-mig.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "google_compute_url_map" "flask_app_lb" {
  default_service = "google_compute_backend_service.flask_backend.id"
  name            = "flask-app-lb"
  region          = "us-central1"
}

resource "google_compute_target_http_proxy" "flask_app_lb_target_proxy" {
  name    = "flask-app-lb-target-proxy"
  url_map = "google_compute_url_map.flask_app_lb.id"
}

#LB Frontend
resource "google_compute_global_forwarding_rule" "flask_app_frontend" {
  ip_address            = "google_compute_address.static-external.id"
  ip_protocol           = "TCP"
  ip_version            = "IPV4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  name                  = "flask-app-frontend"
  port_range            = "80"
  target                = "google_compute_target_http_proxy.flask_app_lb_target_proxy.id"
}