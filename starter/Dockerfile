# syntax=docker/dockerfile:1.0-experimental

#define base image; pinned to a specific Leap release instead of the mutable
#"latest" tag, so a build today pulls the same bits as a build next month
FROM opensuse/leap:15.6

#define maintainer
LABEL maintainer="Abdulhakeem Omotolani Yaqoob"

#define version
LABEL version="V1"

#define the unprivileged user the image will run as
ARG SEC_USER=appuser
ENV SEC_USER=${SEC_USER}

#refresh repos and apply updates, then clean the package cache so it doesn't
#linger in the image layer
RUN zypper refresh && zypper --non-interactive update \
    && zypper clean --all

#create a dedicated, unprivileged system user/group and a directory it owns
RUN groupadd -r ${SEC_USER} \
    && useradd -r -g ${SEC_USER} -d /app -s /sbin/nologin ${SEC_USER} \
    && mkdir -p /app \
    && chown -R ${SEC_USER}:${SEC_USER} /app

WORKDIR /app

#drop root privileges for every instruction/run from here on
USER ${SEC_USER}
