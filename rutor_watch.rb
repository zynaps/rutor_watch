require 'json'
require 'digest'
require 'redis'
require 'redis-namespace'
require 'faraday'
require 'rss'
require 'nokogiri'

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
  feed = RSS::Parser.parse(Faraday.get('http://rutor.info/rss.php?full=1').body)

  feed.items.each do |item|
    release_id = item.link.gsub(%r{.*/torrent/(\d+)}, '\1').to_i
    release_date = item.pubDate
    release_uid = Digest::MD5.hexdigest([release_id, release_date].to_json)

    redis_key = format('seen:%s', release_uid)
    redis.get(redis_key) ? next : redis.set(redis_key, 1)

    next unless (meta = item.title.match(title_re))

    next if meta['label'] =~ /-(A|HE)VC/

    details = Nokogiri::HTML(Faraday.get(item.link).body) rescue next

    # FIXME: more specific xpath
    size_text = details.xpath("//td[text()='Размер']/following-sibling::td").text
    size = (size_text.gsub(/.*\((\d+) Bytes\).*/, '\1').to_f / 1024**3)

    next unless (1..3).member?(size)

    release = meta.names.map { |name| [name, meta[name]] }.to_h

    release['year'] = release['year'].to_i
    release['titles'] = release['titles'].split('/').map(&:strip).join(' / ')
    release['size'] = size
    release['versions'] = release['versions'].split(/[,|]+/).map(&:strip).join(', ')
    release['title'] = format('%s (%d) %s %s | %s | %1.2fGb', *release.values)
    release['url'] = item.link
    release['pub_date'] = release_date
    release['id'] = release_uid

    redis.rpush('entries', release.to_json)

    redis.set('updated', Time.now.to_s)
  end

  sleep 60 * 30
end
