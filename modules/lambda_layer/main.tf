data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${var.build_dir}/layer-${var.name}.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc", "**/tests/**"]
}

resource "aws_lambda_layer_version" "this" {
  layer_name          = var.name
  filename            = data.archive_file.this.output_path
  source_code_hash    = data.archive_file.this.output_base64sha256
  compatible_runtimes = var.compatible_runtimes
}
