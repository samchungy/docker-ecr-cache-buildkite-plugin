# Docker ECR Cache Buildkite Plugin

[![GitHub Release](https://img.shields.io/github/release/seek-oss/docker-ecr-cache-buildkite-plugin.svg)](https://github.com/seek-oss/docker-ecr-cache-buildkite-plugin/releases)

A [Buildkite plugin](https://buildkite.com/docs/agent/v3/plugins) to cache
Docker images in Amazon ECR or Google Container Registry.

This allows you to define a Dockerfile for your build-time dependencies without
worrying about the time it takes to build the image. It allows you to re-use
entire Docker images without worrying about layer caching, and/or pruning layers
as changes are made to your containers.

An ECR repository to store the built Docker image will be created for you, if
one doesn't already exist.

## Example

### Basic usage

```dockerfile
FROM bash

RUN echo 'my expensive build step'
```

```yaml
steps:
  - command: echo wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0
      - docker#v3.3.0
```

### Caching npm packages

This plugin can be used to effectively cache `node_modules` between builds
without worrying about Docker layer cache invalidation. You do this by hinting
when the image should be re-built.

```dockerfile
FROM node:10-alpine

WORKDIR /workdir

COPY package.json package-lock.json /workdir

# this step downloads the internet
RUN npm install
```

```yaml
steps:
  - command: npm test
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          cache-on:
            - package.json # avoid cache hits on stale lockfiles
            - package-lock.json
      - docker#v3.3.0:
          volumes:
            - /workdir/node_modules
```

The `cache-on` property also supports Bash globbing with `globstar`:

```yaml
steps:
  - command: npm test
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          cache-on:
            - '**/package.json' # monorepo with multiple manifest files
            - yarn.lock
      - docker#v3.0.1:
          volumes:
            - /workdir/node_modules
```

### Using another Dockerfile

It's possible to specify the Dockerfile to use by:

```yaml
steps:
  - command: echo wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          dockerfile: my-dockerfile
      - docker#v3.3.0
```

Alternatively, Dockerfile can be embedded inline:

```yaml
steps:
  - command: echo wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          dockerfile-inline: |
            FROM node:16-alpine
            WORKDIR /workdir
            COPY package.json package-lock.json /workdir
            RUN npm install


      - docker#v3.3.0
```

### Specifying a target step

A [multi-stage Docker build] can be used to reduce an application container to
just its runtime dependencies. However, this stripped down container may not
have the environment necessary for running CI commands such as tests or linting.
Instead, the `target` property can be used to specify an intermediate build
stage to run commands against:

[multi-stage docker build]: https://docs.docker.com/develop/develop-images/multistage-build/

```yaml
steps:
  - command: cargo test
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          target: build-deps
      - docker#v3.3.0
```

### Specifying build context

The subdirectory containing the Dockerfile is the path used for the build's context by default.

The `context` property can be used to specify a different path.

```yaml
steps:
  - command: cargo test
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          dockerfile: dockerfiles/test/Dockerfile
          context: '.'
      - docker#v3.3.0
```

### Specifying build args

[Build-time variables] are supported, either with an explicit value, or without
one to propagate an environment variable from the pipeline step:

[build-time variables]: https://docs.docker.com/engine/reference/commandline/build/#set-build-time-variables---build-arg

```dockerfile
FROM bash

ARG ARG_1
ARG ARG_2

RUN echo "${ARG_1}"
RUN echo "${ARG_2}"
```

```yaml
steps:
  - command: echo amaze
    env:
      ARG_1: wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          build-args:
            - ARG_1
            - ARG_2=such
      - docker#v3.3.0
```

Additional `docker build` arguments be passed via the `additional-build-args` setting:

```yaml
steps:
  - command: echo amaze
    env:
      ARG_1: wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          additional-build-args: '--ssh= default=\$SSH_AUTH_SOCK'
      - docker#v3.3.0
```

### Specifying secrets

[Build-time variables] can be extracted from a pulled image, so when passing
sensitive data, [secrets] should be used instead.

[secrets]: https://docs.docker.com/develop/develop-images/build_enhancements/#new-docker-build-secret-information

To use environment variables (perhaps fetched by another plugin) as secrets:

```dockerfile
# syntax=docker/dockerfile:1.2

FROM bash

RUN --mount=type=secret,id=SECRET cat /run/secrets/SECRET
```

```yaml
steps:
  - command: echo amaze
    env:
      SECRET: wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          secrets:
            - SECRET
      - docker#v3.3.0
```

You must have a recent version of Docker with BuildKit enabled to use secrets.

### Changing the max cache time

By default images are kept in ECR for up to 30 days. This can be changed by specifying a `max-age-days` parameter:

```yaml
steps:
  - command: echo wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          max-age-days: 7
      - docker#v3.3.0
```

### Changing the name of exported variable

By default image name and computed tag are exported to the Docker buildkite plugin env variable `BUILDKITE_PLUGIN_DOCKER_IMAGE`. In order to chain the plugin with a different plugin, this can be changed by specifying a `export-env-variable` parameter:

```yaml
steps:
  - command: echo wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          export-env-variable: BUILDKITE_PLUGIN_MY_CUSTOM_PLUGIN_CACHE_IMAGE
      - my-custom-plugin#v1.0.0:
```

### AWS ECR specific configuration

#### Specifying an ECR repository name

The plugin pushes and pulls Docker images to and from an ECR repository named
`build-cache/${BUILDKITE_ORGANIZATION_SLUG}/${BUILDKITE_PIPELINE_SLUG}`. You can
optionally use a custom repository name:

```yaml
steps:
  - command: echo wow
    plugins:
      - seek-oss/docker-ecr-cache#v1.9.0:
          ecr-name: my-unique-repository-name
          ecr-tags:
            Key: Value
            Key2: Value2
      - docker#v3.3.0
```

#### Required permissions

Below is a sample set of IAM policy statements that will allow this plugin to work:

```yaml
- Sid: AllowRepositoryActions
  Action:
    - ecr:BatchCheckLayerAvailability
    - ecr:BatchGetImage
    - ecr:CompleteLayerUpload
    - ecr:CreateRepository
    - ecr:DescribeImages
    - ecr:DescribeRepositories
    - ecr:InitiateLayerUpload
    - ecr:PutImage
    - ecr:PutLifecyclePolicy
    - ecr:SetRepositoryPolicy
    - ecr:UploadLayerPart
  Effect: Allow
  Resource:
    - Fn::Sub: arn:aws:ecr:*:${AWS::AccountId}:repository/build-cache/${YourOrganisationSlug}/${YourPipelineSlug}
- Sid: AllowGetAuthorizationToken
  Action:
    - ecr:GetAuthorizationToken
  Resource: '*'
  Effect: Allow
```

### GCP GCR specific configuration

[Overview of Google Container Registry](https://cloud.google.com/container-registry/docs/overview)

Example:

```yaml
- command: echo wow
  plugins:
    - seek-oss/docker-ecr-cache#v1.9.0:
        registry-provider: gcr
        gcp-project: foo-bar-123456
```

#### Required GCR configuration

- `registry-provider`: this must be `gcr` to aim at a google container registry.
- `gcp-project`: this must be supplied. It is the GCP project your GCR is set up inside.

#### Optional GCR configuration

- `registry-hostname` (default: `gcr.io`). The location your image will be stored. [See upstream docs](https://cloud.google.com/container-registry/docs/overview#registry_name) for options.

## Design

The plugin derives a checksum from:

- The argument names and values specified in the `build-args` property
- The files specified in the `cache-on` and `dockerfile` properties

This checksum is used as the Docker image tag to find and pull an existing
cached image from ECR, or to build and push a new image for subsequent builds to
use.

The plugin handles the creation of a dedicated ECR repository for the pipeline
it runs in. To save on [ECR storage costs] and give images a chance to update/patch, a [lifecycle policy] is
automatically applied to expire images after 30 days (configurable via `max-age-days`).

[ecr storage costs]: https://aws.amazon.com/ecr/pricing/
[lifecycle policy]: https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html

## Tests

To run the tests of this plugin, run

```bash
docker-compose run --rm tests
```

## License

MIT (see [LICENSE](LICENSE))
