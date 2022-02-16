FROM rancher/cli2:v2.4.12 as ranchercli

# FROM viaductoss/ksops:v3.0.1 as ksops-builder

FROM ruby:2.7.5-slim AS ruby


RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install -y build-essential \
                       apt-transport-https \
                       git curl wget \
                       cmake \
                       libpq-dev \
                       libssl-dev \
                       libcurl4-openssl-dev && \
    curl -fsSL https://deb.nodesource.com/setup_12.x | bash - && \
    apt-get install -y nodejs

RUN node -v
RUN npm -v

# install rancher CLI
COPY --from=ranchercli /usr/bin/rancher /usr/local/bin

# install kubectl
ENV KUBECTL_VERSION=v1.21.0
RUN curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# install sops
ENV SOPS_VERSION=3.7.1
RUN curl -sLO "https://github.com/mozilla/sops/releases/download/v${SOPS_VERSION}/sops_${SOPS_VERSION}_amd64.deb" && \
    dpkg -i sops_${SOPS_VERSION}_amd64.deb

# install age
ENV AGE_VERSION=v1.0.0
RUN curl -sLO "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" && \
    tar xzf age-${AGE_VERSION}-linux-amd64.tar.gz && \
    install -o root -g root -m 0755 age/age /usr/local/bin/age

# install helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
    chmod 700 get_helm.sh && \
    ./get_helm.sh

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