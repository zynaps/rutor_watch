FROM ruby:alpine

WORKDIR /

COPY . ./

RUN \
  set -xe && \
  apk add --update --no-cache build-base && \
  bundle install --without development test && \
  apk del build-base

CMD ["ruby", "rutor_watch.rb"]
