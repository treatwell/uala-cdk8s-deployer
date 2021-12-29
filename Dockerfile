FROM rancher/cli2:v2.4.12 as ranchercli

FROM viaductoss/ksops:v3.0.1 as ksops-builder

FROM ruby:2.6.2-slim AS base

RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install -y build-essential \
                       apt-transport-https \
                       git curl wget \
                       cmake \
                       libpq-dev \
                       libssl-dev \
                       libcurl4-openssl-dev

# install rancher CLI
COPY --from=ranchercli /usr/bin/rancher /usr/local/bin

# install kubectl
ENV KUBECTL_VERSION=v1.21.0
RUN curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# install kustomize && kops
ENV XDG_CONFIG_HOME=$HOME/.config
ENV KUSTOMIZE_PLUGIN_PATH=$XDG_CONFIG_HOME/kustomize/plugin/
ARG PKG_NAME=ksops
# Override the default kustomize executable with the Go built version
COPY --from=ksops-builder /go/bin/kustomize /usr/local/bin/kustomize
# Copy the plugin to kustomize plugin path
COPY --from=ksops-builder /go/src/github.com/viaduct-ai/kustomize-sops/*  $KUSTOMIZE_PLUGIN_PATH/viaduct.ai/v1/${PKG_NAME}/

# install sops
ENV SOPS_VERSION=3.7.1
RUN curl -sLO "https://github.com/mozilla/sops/releases/download/v${SOPS_VERSION}/sops_${SOPS_VERSION}_amd64.deb" && \
    dpkg -i sops_${SOPS_VERSION}_amd64.deb

# install age
ENV AGE_VERSION=v1.0.0-rc.3
RUN curl -sLO "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" && \
    tar xzf age-${AGE_VERSION}-linux-amd64.tar.gz && \
    install -o root -g root -m 0755 age/age /usr/local/bin/age

# Remove unused packages
RUN apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app

COPY Gemfile ./Gemfile
COPY Gemfile.lock ./Gemfile.lock
RUN gem install bundler && \
    bundle install

COPY . .
RUN chmod +x ./deployer.rb

CMD ["./deployer.rb"]