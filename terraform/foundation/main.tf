terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.45.0"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 7.45.0"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  required_apis = [
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "networkservices.googleapis.com",
    "networksecurity.googleapis.com",
    "agentregistry.googleapis.com",
    "modelarmor.googleapis.com"
  ]
}

# ---------------------------------------------------------
# APIs
# ---------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------

resource "google_artifact_registry_repository" "agent_images" {
  location      = var.region
  repository_id = "agent-images"
  description   = "Container images for Agent Runtime"
  format        = "DOCKER"

  depends_on = [
    google_project_service.apis
  ]
}

# ---------------------------------------------------------
# VPC
# ---------------------------------------------------------

resource "google_compute_network" "agent_vpc" {
  name                    = "agent-demo-vpc"
  auto_create_subnetworks = false

  depends_on = [
    google_project_service.apis
  ]
}

resource "google_compute_subnetwork" "agent_subnet" {
  name          = "agent-demo-subnet"
  region        = var.region
  network       = google_compute_network.agent_vpc.id
  ip_cidr_range = "10.10.0.0/24"
}

# ---------------------------------------------------------
# Network Attachment
# ---------------------------------------------------------

resource "google_compute_network_attachment" "agent_gateway" {
  provider = google-beta

  name                  = "agent-demo-attachment"
  region                = var.region
  connection_preference = "ACCEPT_AUTOMATIC"

  subnetworks = [
    google_compute_subnetwork.agent_subnet.id
  ]
}

# ---------------------------------------------------------
# Agent Gateway — Client → Agent
# ---------------------------------------------------------

resource "google_network_services_agent_gateway" "ingress" {
  provider = google-beta

  name     = "agent-demo-ingress"
  location = var.region

  protocols = ["MCP"]

  google_managed {
    governed_access_path = "CLIENT_TO_AGENT"
  }

  depends_on = [
    google_project_service.apis
  ]
}

# ---------------------------------------------------------
# Agent Gateway — Agent → Anywhere
# ---------------------------------------------------------

resource "google_network_services_agent_gateway" "egress" {
  provider = google-beta

  name     = "agent-demo-egress"
  location = var.region

  protocols = ["MCP"]

  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }

  network_config {
    egress {
      network_attachment = google_compute_network_attachment.agent_gateway.id
    }
  }

  depends_on = [
    google_project_service.apis
  ]
}

# ---------------------------------------------------------
# Model Armor
# ---------------------------------------------------------

resource "google_model_armor_template" "agent_security" {
  project     = var.project_id
  location    = var.region
  template_id = "agent-demo-security"

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }

    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }

    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "HIGH"
      }
    }

    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
  }

  template_metadata {
    enforcement_type        = "INSPECT_AND_BLOCK"
    log_sanitize_operations = true
  }

  depends_on = [
    google_project_service.apis
  ]
}