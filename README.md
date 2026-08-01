# TeslaMate Configuration

This repository provides a Docker Compose setup to self-host [TeslaMate](https://github.com/teslamate-org/teslamate), an open-source data logger and visualization tool for Tesla vehicles. Use this configuration to quickly deploy TeslaMate, PostgreSQL, Mosquitto, Grafana, and Prometheus.

## Prerequisites

- Docker (>= 20.10)
- Docker Compose (>= 1.29)
- A Tesla vehicle account for data access

## Getting Started

1. Clone this repository:
   ```bash
   git clone https://github.com/ben-z/teslamate-conf.git
   cd teslamate-conf
   ```

2. Copy the example environment file and customize it:
   ```bash
   cp .env.example .env
   # Edit .env to set your credentials and preferred settings
   ```

3. Configure any additional settings in `docker-compose.yml` if you need custom ports or volumes.

4. Start the rootful Docker stack:
   ```bash
   sudo docker compose up -d
   ```

5. Verify services are running:
   ```bash
   sudo docker compose ps
   ```

## Configuration

Edit variables in your `.env` file.

## Accessing the Services

- **TeslaMate UI**: http://localhost:4000
- **Grafana**: http://localhost:3001 (default: `admin`/`admin`)
- **Prometheus**: http://localhost:9090

## Logs & Management

- View logs: `sudo docker compose logs -f`
- Stop services: `sudo docker compose down`
- Apply image changes: `sudo docker compose pull && sudo docker compose up -d`

## Operational Runbooks

See [TeslaMate upgrade and mileage backfill](docs/UPGRADE_AND_BACKFILL.md) for:

- why this deployment moved from TeslaMate 2.1.1 to 4.0.1;
- how to create and verify a PostgreSQL backup before upgrading;
- how to upgrade the rootful Docker Compose deployment safely; and
- how to diagnose and reconstruct mileage after an API outage without turning weeks of raw positions into a single drive.

## Backup & Data Retention

- Database data is persisted in `./data/teslamate-db`
- Grafana data is in `./data/grafana`
- Mosquitto data is in `./data/mosquitto-data` and `./data/mosquitto-conf`

Regularly back up the data in the `./data` directory. Before upgrades or database maintenance, also create a logical PostgreSQL dump as described in the operational runbook.

## Troubleshooting

- Ensure your Tesla credentials are correct and 2FA is disabled or handled appropriately.
- Check port conflicts on your host machine.
- Review logs for errors:
  ```bash
  sudo docker compose logs teslamate
  ```
