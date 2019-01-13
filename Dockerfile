FROM ruby:alpine
LABEL maintainer="Igor Vinokurov <zynaps@zynaps.ru>"

WORKDIR /

COPY . ./

RUN \
  set -xe && \
  apk add --update --no-cache build-base && \
  bundle install --without development test && \
  apk del build-base

CMD ["ruby", "rutor_watch.rb"]
