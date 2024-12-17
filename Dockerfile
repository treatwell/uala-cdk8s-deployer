# hadolint global ignore=DL3008,DL3009
FROM ruby:3.3-slim-bookworm

RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install --no-install-recommends -y \
    apt-transport-https \
    git \
    curl \
    unzip \
    groff \
    build-essential \
    libssl-dev \
    libcurl4-openssl-dev

# Install Node.js via NVM (Node Version Manager)
ENV NVM_VERSION=v0.40.1
RUN curl -fsSL -o install_nvm.sh "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" && \
    chmod 700 install_nvm.sh && \
    ./install_nvm.sh && \
    rm install_nvm.sh && \
    export NVM_DIR="$HOME/.nvm" && \
    . "$NVM_DIR/nvm.sh" && \
    nvm install --lts --default --save && \
    nvm install-latest-npm && \
    ln -s $NVM_BIN /usr/local/bin/nvm-node
ENV PATH=/usr/local/bin/nvm-node:$PATH

# install aws CLI
RUN curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip -qq awscliv2.zip && ./aws/install && rm -rf ./aws && \
    rm -rf awscliv2.zip

# install kubectl
ENV KUBECTL_VERSION=v1.31.4
RUN curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm -rf kubectl

# install sops
ENV SOPS_VERSION=3.9.2
RUN curl -sLO "https://github.com/mozilla/sops/releases/download/v${SOPS_VERSION}/sops_${SOPS_VERSION}_amd64.deb" && \
    dpkg -i sops_${SOPS_VERSION}_amd64.deb && \
    rm -rf sops_${SOPS_VERSION}_amd64.deb

# install age
ENV AGE_VERSION=v1.2.0
RUN curl -sLO "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" && \
    tar xzf age-${AGE_VERSION}-linux-amd64.tar.gz && \
    install -o root -g root -m 0755 age/age /usr/local/bin/age && \
    rm -rf age-${AGE_VERSION}-linux-amd64.tar.gz && \
    rm -rf age

# install helm
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
    chmod 700 get_helm.sh && \
    ./get_helm.sh && \
    rm get_helm.sh

# Remove unused packages
RUN apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app

ENV BUNDLER_VERSION=2.5.23
COPY Gemfile ./Gemfile
COPY Gemfile.lock ./Gemfile.lock
RUN gem install bundler:"$BUNDLER_VERSION" && \
    bundle install && \
    rm -rf /usr/local/bundle/cache/*.gem && \
    rm -rf /usr/local/bundle/ruby/"$RUBY_MAJOR".0/cache/*.gem

COPY . .
RUN chmod +x ./deployer.rb

CMD ["/usr/src/app/deployer.rb"]
