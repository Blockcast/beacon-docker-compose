# cdn-compose

Docker Compose for installing CDN gateways.

## Install
Pulls the image associated with the service defined in the compose.yaml file:

```bash
docker compose pull
```

## Registration

Start Blockcast services:

```bash
docker compose up -d
```

Get Node info by running:
```bash
docker compose exec -u blockcast blockcastd blockcastd init
```

Register using the provided URL or by using the Hardware ID and Challenge Key manually.
