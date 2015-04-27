# push2docker

You can use `push2docker` to create a Docker image that very closely resembles a Cloud Foundry droplet. `push2docker` takes a buildpack as an input and creates a Docker image with the same OS, file structure, and environment variables as a droplet.

## Prerequisites

1. Ubuntu 14.04 with Docker installed.

## Usage

1. Create a directory and clone this project.
2. Run `./push2docker/push <appName> -p <PATH> -b <BUILDPACK_URL>` to create the Docker image. For example:

```bash
$  ./push2docker/push ferret -p ferret.war -b https://github.com/cloudfoundry/java-buildpack
```
3. The created Docker image will the tagged with the given `<appName>`. Once the image is created you can run it, for example:

```bash
$ docker run -t ferret -p 8080:8080
```

