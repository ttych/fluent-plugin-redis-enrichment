# fluent-plugin-redis-enrichment

Filter plugin that allow to update record with data fetch from redis.

## Behaviour

- try to do record enrichment using redis content,
- fetch redis data based on a key that can be hardcoded or in the record
- enrich record with redis fetched data
- in case of failure in the processing, skip enrichment and let processing
  continue on record

## Installation


Manual install, by executing:

    $ gem install fluent-plugin-redis-enrichment

Add to Gemfile with:

    $ bundle add fluent-plugin-redis-enrichment

## Compatibility

### 1.x.x

plugin in 1.x.x will work with:
- ruby >= 2.4.10
- td-agent >= 3.8.1-0

and so use:
- redis > 4, < 5

### 2.x.x

will come next !

## Configuration

### template
You can generate configuration template:

```
$ fluent-plugin-config-format filter redis-enrichment
```

You can copy and paste generated documents here.

### example

- in the current record, get the value associated to *field* key,
- use this value in redis to get associated data
- complete current record with fetched redis data

```
<filter data_stream_tag>
  @type redis_enrichment

  sentinels "sentinel-1:26379,sentinel-2:26379,sentinel-:26379"
  sentinel_password "abc123"
  sentinel_master "mymaster"
  redis_db "1"
  redis_password "123abc"

  key ${record["field"]}

  <record>
    additional_1 "${redis["data1"]}"
    additional_2 "${redis["data2"]}"
  </record>
</filter>
```

## Copyright

* Copyright(c) 2022- Thomas Tych
* License
  * Apache License, Version 2.0
