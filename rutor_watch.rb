require 'json'
require 'digest'
require 'redis'
require 'redis-namespace'
require 'httpclient'
require 'rss'
require 'nokogiri'

def http_get(*args)
  cache = Redis::Namespace.new('httpclient', redis: Redis.new)

  cache_key = Digest::MD5.hexdigest(*args.to_json)

  unless (body = cache.get(cache_key))
    body = (response = HTTPClient.get(*args)).body rescue nil

    if (200..299).member?(response.status)
      cache.set(cache_key, body)
      cache.expire(cache_key, 60 * 15)
    end
  end

  body
end

redis = Redis::Namespace.new('feeds:rutor_watch', redis: Redis.new)

redis.set('author', 'zynaps@zynaps.ru')
redis.set('about', 'http://rutor.info/kino')
redis.set('title', 'rutor.info watch')

title_re = %r{
  (?<titles>.*)\s+
  \((?<year>\d+)\)\s+
  (?<label>[\w\s-]+)\s+от\s+
  (?<team>.*?)\s+\|\s+
  (?<versions>.*)
}x

loop do
  feed = RSS::Parser.parse(http_get('http://rutor.info/rss.php?full=1', follow_redirect: true))

  feed.items.each do |item|
    release_id = item.link.gsub(%r{.*/torrent/(\d+)}, '\1').to_i
    release_date = item.pubDate
    release_uid = Digest::MD5.hexdigest([release_id, release_date].to_json)

    next if redis.get(redis_key = format('seen:%s', release_uid))

    redis.set(redis_key, 1)
    redis.expire(redis_key, 60 * 60 * 24 * 7)

    details = Nokogiri::HTML(item.description)

    imdb_xpath = "//a/@href[contains(., 'imdb.com/title/')]"
    kpdb_xpath = "//a/@href[contains(., 'kinopoisk.ru/film/')]"

    imdb_id = details.at_xpath(imdb_xpath)&.value&.gsub(%r{.*/tt(\d+)/?$}, '\1')
    kpdb_id = details.at_xpath(kpdb_xpath)&.value&.gsub(%r{.*/film/.*?-?(\d+)/?$}, '\1')

    if imdb_id && kpdb_id
      redis.setnx(format('imdb_ids:%s', kpdb_id), imdb_id)
      redis.setnx(format('kpdb_ids:%s', imdb_id), kpdb_id)
    else
      imdb_id ||= redis.get(format('imdb_ids:%s', kpdb_id))
      kpdb_id ||= redis.get(format('kpdb_ids:%s', imdb_id))
    end

    next unless (meta = item.title.match(title_re))

    next if meta['label'] =~ /-(A|HE)VC/

    details = Nokogiri::HTML(http_get(item.link, follow_redirect: true)) rescue next

    size_xpath = "//td[@class='header' and text()='Размер']/following-sibling::td"
    size = (details.xpath(size_xpath).text.gsub(/.*\((\d+) Bytes\).*/, '\1').to_f) / 1024**3

    next unless (1..3).member?(size)

    release = meta.names.map { |name| [name, meta[name]] }.to_h

    release['year'] = release['year'].to_i
    release['titles'] = release['titles'].split('/').map(&:strip).join(' / ')
    release['size'] = size
    release['versions'] = release['versions'].split(/[,|]+/).map(&:strip).join(', ')
    release['title'] = format('%s (%d) %s %s | %s | %1.2fGb', *release.values)
    release['content'] = item.description
    release['url'] = item.link
    release['pub_date'] = release_date
    release['id'] = release_uid

    redis.rpush('entries', release.to_json)

    redis.set('updated', Time.now.to_s)
  end

  sleep 60 * 30
end
