FROM python:3.12-slim

ARG ANSIBLE_VERSION=2.17.14

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-client \
        sshpass \
        git \
        ca-certificates \
        bash \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "ansible-core==${ANSIBLE_VERSION}"

WORKDIR /workspace

COPY ansible.cfg /workspace/ansible.cfg
COPY inventory /workspace/inventory
COPY group_vars /workspace/group_vars
COPY roles /workspace/roles
COPY site.yml /workspace/site.yml

ENTRYPOINT ["ansible-playbook"]
CMD ["--version"]
