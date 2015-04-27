# push2docker

You can use `push2docker` to create a Docker image that very closely resembles a Cloud Foundry droplet. `push2docker` takes a buildpack as an input and creates a Docker image with the same OS, file structure, and environment variables as a droplet.

## Prerequisites

1. Ubuntu 14.04 with Docker installed.

## Usage

1. Clone this project.
2. In the `push2docker` directory run `./push <appName> -p <PATH> -b <BUILDPACK_URL>` to create the Docker image. For example:

```bash
$  ./push ferret -p /samples/ferret.war -b https://github.com/cloudfoundry/java-buildpack
```
You can pass additional environment variables using `-e` option. For example:

```bash
$ ./push ferret -p /samples/ferret.war -b https://github.com/cloudfoundry/ibm-websphere-liberty-buildpack.git -e IBM_JVM_LICENSE=XXX -e IBM_LIBERTY_LICENSE=YYY
```

The `<PATH>` value for `-p` argument must be an absolute path to a file or a directory.

3. The created Docker image will the tagged with the given `<appName>`. Once the image is created you can run it, for example:

```bash
$ docker run -t -p 8080:8080 ferret
```

