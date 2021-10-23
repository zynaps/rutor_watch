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

redis = Redis::Namespace.new('feeder:rutor_filtered', redis: Redis.new)

redis.setnx('title', 'rutor filtered')

title_re = %r{
  (?<titles>.*)\s+
  \((?<year>\d+)\)\s+
  (?<label>[\w\s-]+)\s+от\s+
  (?<team>.*?)\s+\|\s+
  (?<versions>.*)
}x

loop do
  feed = RSS::Parser.parse(http_get('http://www.rutor.info/rss.php?full=1', follow_redirect: true))

  feed.items.each do |item|
    release_id = Digest::MD5.hexdigest([item.link.gsub(%r{.*/torrent/(\d+)}, '\1'), item.pubDate].to_json)

    next unless redis.setnx(seen_key = format('seen:%s', release_id), 1)

    redis.expire(seen_key, 60 * 60 * 24 * 7)

    details = Nokogiri::HTML(item.description)

    imdb_id = details.at_xpath("//a/@href[contains(., 'imdb.com/title/')]")&.value&.gsub(%r{.*/tt(\d+)/?$}, '\1')
    kpdb_id = details.at_xpath("//a/@href[contains(., 'kinopoisk.ru/film/')]")&.value&.gsub(%r{.*/film/.*?-?(\d+)/?$}, '\1')

    if imdb_id && kpdb_id
      redis.setnx(format('imdb_ids:%s', kpdb_id), imdb_id)
      redis.setnx(format('kpdb_ids:%s', imdb_id), kpdb_id)
    else
      imdb_id ||= redis.get(format('imdb_ids:%s', kpdb_id))
      kpdb_id ||= redis.get(format('kpdb_ids:%s', imdb_id))
    end

    next unless (meta = item.title.match(title_re))

    details = Nokogiri::HTML(http_get(item.link, follow_redirect: true)) rescue next

    size = (details.xpath("//td[@class='header' and text()='Размер']/following-sibling::td").text.gsub(/.*\((\d+) Bytes\).*/, '\1').to_f) / 1024**3
    genres = details.xpath("//table['details']//b[contains(., 'Жанр')]/following-sibling::a/text()").map { |a| a.text.downcase }

    next unless (1..3).member?(size) && genres.none?('ужасы')

    if imdb_id
      ratings = Nokogiri::HTML(http_get(format('https://www.imdb.com/title/tt%09d/ratings', imdb_id), follow_redirect: true)) rescue next

      imdb_rating = ratings.xpath("//div[@class='allText']/div[@class='allText']").text.split(/\n/)[2].scan(/(\d+\.\d+) \/ 10/)[0][0].to_f
      imdb_votes = ratings.xpath("//div[@class='allText']/div[@class='allText']").text.split(/\n/)[1].delete(' ,').to_i

      next if imdb_rating < 5 && imdb_votes > 1000
    end

    release = meta.names.map { |name| [name, meta[name]] }.to_h

    release['year'] = release['year'].to_i
    release['titles'] = release['titles'].split('/').map(&:strip).join(' / ')
    release['size'] = size
    release['versions'] = release['versions'].split(/[,|]+/).map(&:strip).join(', ')
    release['title'] = format('%s (%d) %s %s | %s | %1.2fGb', *release.values)
    release['content'] = item.description
    release['link'] = item.link
    release['updated'] = item.pubDate
    release['id'] = release_id

    redis.lpush('entries', release.to_json)
    redis.ltrim('entries', 0, 99)
  end

  sleep 60 * 30
end
