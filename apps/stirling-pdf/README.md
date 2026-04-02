 
# Stirling-PDF – Self-Hosted PDF Tools (Docker Setup)

This repository contains a Docker Compose stack for [Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF),
a self-hosted web application for PDF manipulation including merging, splitting, converting, and OCR.
Supported architectures: `amd64`, `arm`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `stirling-pdf` | `stirlingtools/stirling-pdf:2.8.0` | Main application, exposed via `EXPORT_PORT` |

The service mounts dedicated volumes for OCR training data, configuration, custom files, logs, and pipeline processing.

## Quickstart

1. Copy the env template and adjust values as needed:
   ```bash
   cp env-dist .env
   ```
2. Pull the image:
   ```bash
   docker compose pull
   ```
3. Start the stack:
   ```bash
   docker compose up -d
   ```

**Update:** `docker compose pull && docker compose up -d`

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `EXPORT_PORT` | `16780` | Host port the web UI is exposed on |
| `LANGS` | `de_DE` | OCR language(s) for Tesseract processing |
| `DISABLE_ADDITIONAL_FEATURES` | `false` | Set to `true` to hide advanced/premium-style features |
| `tessdata_trainingData` | `./data/trainingData` | Path to Tesseract OCR language/training data |
| `extraConfigs` | `./data/configs` | Path to extra application configuration files |
| `customFiles` | `./data/customFiles` | Path to custom static files (e.g. fonts, templates) |
| `logs` | `./data/logs` | Path to application log output |
| `pipeline` | `./data/pipeline` | Path to pipeline definitions for batch processing |

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` if the instance contains sensitive configuration.

## Data Directories

All persistent data is stored on the host under `./data/` by default:

| Path | Purpose |
|---|---|
| `./data/trainingData` | Tesseract OCR language models (required for non-default languages) |
| `./data/configs` | Application configuration overrides |
| `./data/customFiles` | User-provided custom files served by the application |
| `./data/logs` | Runtime log files |
| `./data/pipeline` | Batch processing pipeline definitions |

> **OCR languages:** The `tessdata_trainingData` volume is required for any language beyond the built-in default. Additional language packs must be placed here manually or pre-downloaded into the container.