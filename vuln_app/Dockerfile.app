FROM python:3.12-alpine

# Pull in the latest patched versions of whatever OS packages are already
# in this Alpine release's repo (closes known-fixed CVEs in zlib etc.
# without waiting on a base image rebuild), and pin pip itself to a patched release.
RUN apk upgrade --no-cache \
    && pip install --no-cache-dir --upgrade pip

RUN apk add --no-cache wget \
    && wget -O /usr/bin/wait-for https://raw.githubusercontent.com/eficode/wait-for/master/wait-for \
    && chmod +x /usr/bin/wait-for \
    && apk del wget

COPY requirements.txt /tmp

RUN apk add --no-cache --virtual build-deps gcc python3-dev musl-dev \
    && apk add --no-cache postgresql-dev \
    && pip install --no-cache-dir -r /tmp/requirements.txt \
    && apk del build-deps

RUN rm -rf /tmp/requirements.txt

WORKDIR /app
ADD ./run.py /app
ADD ./sqli /app/sqli
ADD ./config /app/config
