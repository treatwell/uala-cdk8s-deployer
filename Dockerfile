FROM rancher/cli2:v2.7.0 as ranchercli

FROM ruby:3.2.2-slim-bookworm AS ruby


RUN apt-get update -qq && \
    apt-get upgrade -y && \
    apt-get install -y \
                       apt-transport-https \
                       git curl unzip \
                       groff \
                       libssl-dev \
                       libcurl4-openssl-dev

# install nodejs
RUN apt-get install -y ca-certificates curl gnupg && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

ENV NODE_MAJOR=20
RUN echo "deb  [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
    | tee /etc/apt/sources.list.d/nodesource.list
RUN apt-get update && apt-get install -y nodejs

RUN node -v
RUN npm -v

# install rancher CLI
COPY --from=ranchercli /usr/bin/rancher /usr/local/bin

# install aws CLI
RUN curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip -qq awscliv2.zip && ./aws/install && rm -rf ./aws && rm -rf awscliv2.zip

# install kubectl
ENV KUBECTL_VERSION=v1.23.0
RUN curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -rf kubectl

# install sops
ENV SOPS_VERSION=3.7.3
RUN curl -sLO "https://github.com/mozilla/sops/releases/download/v${SOPS_VERSION}/sops_${SOPS_VERSION}_amd64.deb" && \
    dpkg -i sops_${SOPS_VERSION}_amd64.deb && rm -rf sops_${SOPS_VERSION}_amd64.deb

# install age
ENV AGE_VERSION=v1.1.1
RUN curl -sLO "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" && \
    tar xzf age-${AGE_VERSION}-linux-amd64.tar.gz && \
    install -o root -g root -m 0755 age/age /usr/local/bin/age && \
    rm -rf age-${AGE_VERSION}-linux-amd64.tar.gz && rm -rf age

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
    bundle install  && \
    rm -rf /usr/local/bundle/cache/*.gem && \
    rm -rf /usr/local/bundle/ruby/$RUBY_MAJOR.0/cache/*.gem

COPY . .
RUN chmod +x ./deployer.rb

CMD ["/usr/src/app/deployer.rb"]
