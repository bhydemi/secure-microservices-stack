# syntax=docker/dockerfile:1.0-experimental

#define base image; replace with your image location once hardened
FROM opensuse/leap:latest

#define maintainer
LABEL maintainer="Abdulhakeem Omotolani Yaqoob"

#define version
LABEL version="V1"

# create a directory to work in
RUN mkdir app \
    && cd app

#install zypper 
RUN zypper refs && zypper refresh

#add local user
USER $SEC_USER
