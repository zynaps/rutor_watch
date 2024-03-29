require 'digest'
require 'httpclient'
require 'json'
require 'nokogiri'
require 'redis-namespace'
require 'redis'
require 'rss'

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

db = Redis.new

feed_entries = Redis::Namespace.new('feeder:rutor_filtered', redis: db)
torrents_seen = Redis::Namespace.new('rutor_watch:torrents_seen', redis: db)
movie_ids = Redis::Namespace.new('rutor_watch:movie_ids', redis: db)

feed_entries.setnx('title', 'rutor filtered')

title_re = %r{
  (?<titles>.*)\s+
  \((?<year>\d+)\)\s+
  (?<label>[\w\s-]+)\s+от\s+
  (?<team>.*?)\s+\|\s+
  (?<versions>.*)
}x

$stdout.sync = true

loop do
  rss_items = RSS::Parser.parse(http_get('http://rutor.is/rss.php?full=1', follow_redirect: true)).items

  new_torrents = new_releases = 0

  rss_items.each do |item|
    release_id = Digest::MD5.hexdigest([item.link.gsub(%r{.*/torrent/(\d+)}, '\1'), item.pubDate].to_json)

    next unless torrents_seen.setnx(seen_key = format('%s', release_id), 1)

    torrents_seen.expire(seen_key, 60 * 60 * 24 * 7)

    new_torrents += 1

    details = Nokogiri::HTML(item.description)

    imdb_id = details.at_xpath("//a/@href[contains(., 'imdb.com/title/')]")&.value&.gsub(%r{.*/tt(\d+)/?$}, '\1')
    kpdb_id = details.at_xpath("//a/@href[contains(., 'kinopoisk.ru/')]")&.value&.gsub(%r{.*/film/.*?-?(\d+)/?$}, '\1')

    if imdb_id && kpdb_id
      movie_ids.setnx(format('imdb:%s', kpdb_id), imdb_id)
    elsif kpdb_id
      imdb_id = movie_ids.get(format('imdb:%s', kpdb_id))
    end

    next unless (meta = item.title.match(title_re))

    details = Nokogiri::HTML(http_get(item.link, follow_redirect: true)) rescue next

    size = (details.xpath("//td[@class='header' and text()='Размер']/following-sibling::td").text.gsub(/.*\((\d+) Bytes\).*/, '\1').to_f) / 1024**3
    genres = details.xpath("//table['details']//b[contains(., 'Жанр')]/following-sibling::a/text()").map { |a| a.text.downcase }

    next unless (1..3).member?(size) && genres.none?('ужасы')

    release = meta.names.map { |name| [name, meta[name]] }.to_h

    release['year'] = release['year'].to_i
    release['titles'] = release['titles'].split('/').map(&:strip).join(' / ')
    release['size'] = size
    release['versions'] = release['versions'].split(/[,|]+/).map(&:strip).join(', ')
    release['title'] = format('%s (%d) %s %s | %s | %1.2fGb', *release.values)
    release['content'] = item.description
    release['content_type'] = 'html'
    release['link'] = item.link
    release['updated'] = item.pubDate
    release['id'] = release_id

    feed_entries.lpush('entries', release.to_json)
    feed_entries.ltrim('entries', 0, 99)

    new_releases += 1
  end

  puts format('Got %d new torrents and discover %d new suitable releases', new_torrents, new_releases)

  sleep(60 * 30)
end
