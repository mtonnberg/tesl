terraform {
  required_version = ">= 1.8.0, < 2.0.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = pathexpand(var.kubeconfig_path)
  }
}

locals {
  chart = "${path.module}/../chart"
  release_values = {
    image         = var.app_image
    revision      = var.revision
    schemaVersion = var.schema_version
  }
}

resource "helm_release" "database" {
  name             = "rolling-database"
  namespace        = var.namespace
  create_namespace = true
  chart            = local.chart
  values           = [yamlencode({ mode = "database" })]
  wait             = true
  wait_for_jobs    = true
  timeout          = 600
  atomic           = false
}

resource "helm_release" "migrator" {
  name          = "rolling-migrator"
  namespace     = var.namespace
  chart         = local.chart
  values        = [yamlencode(merge(local.release_values, { mode = "migrator" }))]
  wait          = true
  wait_for_jobs = true
  timeout       = 600
  atomic        = false
  depends_on    = [helm_release.database]
}

resource "helm_release" "app" {
  name          = "rolling-app"
  namespace     = var.namespace
  chart         = local.chart
  values        = [yamlencode(merge(local.release_values, { mode = "app" }))]
  wait          = true
  wait_for_jobs = true
  timeout       = 600
  atomic        = false
  depends_on    = [helm_release.migrator]
}
