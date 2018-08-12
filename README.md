RTB: Benchmarking tool to stress real-time protocols
====================================================

The idea of RTB is to provide a benchmarking tool to stress test
XMPP and MQTT servers with the minimum configuration overhead.
Also, at least in the XMPP world, a "golden standard" benchmark
is highly demanded in order to compare server implementations,
avoiding disambiguations as much as possible. RTB is believed
to be used in such role because it has sane defaults (gathered
from statistics of real world servers) and it is able to
stress test all features defined in the
[XMPP Compliance Suite 2018](https://xmpp.org/extensions/xep-0387.html)

# Status

RTB is in an early stage of development with the following limitations:
- Supported MQTT version is 3.1.1 only.
- For XMPP protocol support for
  [Multi-User Chat](https://xmpp.org/extensions/xep-0045.html) and
  [Personal Eventing Protocol](https://xmpp.org/extensions/xep-0163.html)
  is lacking.

Also, "sane" defaults and what should be considered a
"golden benchmark" is yet to be discussed within the XMPP and MQTT community.
However, the tool has been already battle-tested:
[ProcessOne](https://www.process-one.net/) is using the tool to
stress test [ejabberd SaaS](https://ejabberd-saas.com/) deployments.

# System requirements

To compile RTB you need:

 - Unix-like OS. Windows is not supported.
 - GNU Make.
 - GCC.
 - Libexpat 1.95 or higher.
 - Libyaml 0.1.4 or higher.
 - Erlang/OTP 18.0 or higher. Erlang/OTP 20 is recommended.
 - OpenSSL 1.0.0 or higher.
 - Zlib 1.2.3 or higher.
 - gnuplot 4.4 or higher.

If your system splits packages in libraries and development headers, you must
install the development packages also.

# Compiling

As usual, the following commands are used to obtain and compile the tool:
```
$ git clone https://github.com/processone/rtb.git
$ cd rtb
$ make
```

# Usage

Once compiled, you will find `rtb.sh`, `rtb.yml.xmpp.example` and
`rtb.yml.mqtt.example` files. Copy either `rtb.yml.mqtt.example` or
`rtb.yml.xmpp.example` to `rtb.yml`, edit it (see section below) and run:
```
$ cp rtb.yml.xmpp.example rtb.yml
$ editor rtb.yml
$ ./rtb.sh
```
Investigate the output of the script for presence of errors. All errors
are supposed to be self-explanatory and most of them have some hints on
what should be done to fix them.

To stop the benchmark press `Ctrl+C+C`. In order to start the
benchmark in background append `-detached` switch:
```
$ ./rtb.sh -detached
```
You will find logs in the `log` directory. To monitor the progress
open the statistics web page: it's located at `http://this.machine.tld:8080`
by default. Edit `www_port` option to change the port if needed.

# Database population

During compilation a special script is created which aims to help
you populating the server's database. It's located at `priv/bin/rtb_db`.

## XMPP scenario

The script is able to generate files for users and rosters in either
CSV format (ejabberd) or in Lua format (Metronome/Prosody).
In order to generate files for ejabberd execute something like:
```
$ priv/bin/rtb_db ejabberd sql 1000 user% domain.tld pass%
```
The same, but for Metronome/Prosody will look like:
```
$ priv/bin/rtb_db prosody flat 1000 user% domain.tld pass%
```
where 1000 is the total amount of users (must match `capacity` parameter
of the configuration file).

Follow the hint provided by the script to load generated files
into the server's spool/database. Note that user, domain and
password arguments must match those defined in the configuration file
(see `jid` and `password` parameters).

# Configuration

All configuration is performed via editing parameters of `rtb.yml` file.
The file has [YAML](http://en.wikipedia.org/wiki/YAML) syntax.
There are mandatory and optional parameters.
The majority of parameters are optional.

## General parameters

These group of parameters are common for all scenarios.

### Mandatory parameters

- **scenario**: `string()`

  The benchmarking scenario to use. Available values are `mqtt` and `xmpp`.

- **interval**: `non_neg_integer()`

  The option is used to set a timeout to wait before spawning
  the next connection. The timeout is in **milliseconds**.

- **capacity**: `pos_integer()`

  The total amount of connections to be spawned.

- **servers**: `[uri()]`

  This parameter is only mandatory for `mqtt` scenario. See next
  section for the detailed description of the parameter.

### Optional parameters

- **certfile**: `string()`

  A path to a certificate file. The file MUST contain both a full certficate
  chain and a private key in PEM format. This option is required in the
  case when your scenario is configured to utilize TLS connections.

- **servers**: `[uri()]`

  The list of server URIs to connect. The format of the URI must be
  `scheme://hostname:port` where `scheme` can be `tls` or `tcp`, `hostname`
  can be any DNS name or IP address and `port` is a port number.
  Note that all parts of the URI are mandatory. IPv6 addresses MUST be
  enclosed in square brackets, e.g. `tcp://[1:2::3:4]:5222`.
  This option is used to set a transport, address and port of the server(s)
  being tested. It's highly recommended to use IP addresses in `hostname`
  part: excessive DNS lookups may create significant overhead for the
  benchmarking tool itself. The default is empty list which means the
  used scenario will detect the server(s) endpoint(s) by its own mechanisms,
  such as DNS SRV lookups. Leaving the default alone is also not recommended
  for the reason described above.

- **bind**: `[ip_address()]`

  The list of IP addresses of local interfaces to bind. The typical
  usage of the option is to set several binding interfaces in order
  to establish more than 64k outgoing connections from the same machine.
  The default is empty list: in this case a binding address will be chosen
  automatically by the OS.

- **stats_file**: `string()`

  A path to the file where statistics will be dumped. The file is used
  by `gnuplot` to generate statistics graphs. The default value is
  `log/stats.log`

- **www_dir**: `string()`

  A path to a directory where HTML and image files will be created.
  The default is `www`. This is used by the statistics web interface.

- **www_port**: `pos_integer()`

  A port number to start the statistics web interface at. The default is 8080.

- **gnuplot**: `string()`

  The path to a gnuplot execution binary. The default is `gnuplot`.

## Parameters of the XMPP scenario

These group of parameters are specific to the XMPP scenario only.
The parameters described here are applied per single session.

### Mandatory parameters

- **jid**: `string()`

  A pattern for an XMPP address: bare or full. If it's bare, the default
  `rtb` resource will be used. The pattern may contain `%` symbol which
  will be replaced by the current connection number. For example, if
  the pattern is `user%@domain.tld/res%` and `capacity` is 5 then
  the following array of XMPP addresses will be generated:
  `user1@domain.tld/res1`, `user2@domain.tld/res2`, `...`, `user5@domain.tld/res5`.

- **password**: `string()`

  The pattern for a password. The pattern may contain `%` symbol with the
  same meaning as in `jid` option.

### Optional parameters

#### Parameters for timings control.

- **negotiation_timeout**: `pos_integer() | false`

  A timeout to wait for a stream negotiation to complete.
  The value is in **seconds**. It can be set to `false` to disable timeout.
  The default is 100 seconds.

- **connect_timeout**: `pos_integer() | false`

  A timeout to wait for a TCP connection to be established.
  The value is in **seconds**. It can be set to `false` to disable timeout.
  The default is 100 seconds.

- **reconnect_interval**: `pos_integer() | false`

  A timeout to wait before another reconnection attempt after previous
  connection failure. Initially it is picked randomly between `1` and this
  configured value. Then, exponential back off is applied between several
  consecutive connection failures. The value is in **seconds**.
  It can be set to `false` to disable reconnection attemps completely:
  thus the failed session will never be restored.
  The default is 60 (1 minute) - the value recommended by
  [RFC6120](https://tools.ietf.org/html/rfc6120#section-3.3).

- **message_interval**: `pos_integer() | false`

  An interval between sending messages. The value is in **seconds**.
  It can be set to `false` to disable sending messages completely.
  The default is 600 (10 minutes). See also `message_body_size` option.

- **presence_interval**: `pos_integer() | false`

  An interval between sending presence broadcats. The value is in **seconds**.
  It can be set to `false` to disable sending presences completely.
  The default is 600 (10 minutes). Note that at the first successful login a
  presence broadcast is always sent unless the value is not set to `false`.

- **disconnect_interval**: `pos_integer() | false`

  An interval to wait before forcing disconnect. If stream management
  is enabled (this is the default, see `sm` option), then the session
  will be resumed after a random timeout between 1 and the value of
  `max` attribute of `<enabled/>` element reported by the server.
  Otherwise, the next reconnection attempt will be performed according
  to the value and logic of `reconnect_interval`.

- **proxy65_interval**: `pos_integer() | false`

  An interval between file transfers via Prox65 service (XEP-0065).
  The value is in **seconds**. It can be set to `false` to disable
  this type of file transfer completely. The default is 600 (10 minutes).
  See also `proxy65_size` option.

- **http_upload_interval**: `pos_integer() | false`

  An interval between file uploads via HTTP Upload service (XEP-0363).
  The value is in **seconds**. It can be set to `false` to disable
  this file uploads completely. The default is 600 (10 minutes).
  See also `http_upload_size` option.

#### Parameters for size control

- **message_body_size**: `non_neg_integer()`

  The size of `<body/>` element of a message in **bytes**.
  Only makes sense when `message_interval` is not set to `false`.
  The default is 100 bytes.

- **proxy65_size**: `non_neg_integer()`

  The size of a file to transfer via Proxy65 service in **bytes**.
  Only makes sense when `proxy65_interval` is not set to `false`.
  The default is 10485760 (10 megabytes).

- **http_upload_size**: `non_neg_integer()`

  The size of a file to upload via HTTP Upload service in **bytes**.
  Only makes sense when `http_upload_interval` is not set to `false`.
  There is no default value: the option is only needed to set
  if the service doesn't report its maximum file size.

#### Parameters for enabling/disabling features

- **starttls**: `true | false`

  Whether to use STARTTLS or not. The default is `true`.

- **csi**: `true | false`

  Whether to send client state indications or not (XEP-0352).
  The default is `true`.

- **sm**: `true | false`

  Whether to enable stream management with resumption or not (XEP-0198).
  The default is `true`.

- **mam**: `true | false`

  Whether to enable MAM and request MAM archives at login time or not (XEP-0313).
  The default is `true`. The requested size of the archive is 20 (messages).

- **carbons**: `true | false`

  Whether to enable message carbons or not (XEP-0280). The default is `true`.

- **blocklist**: `true | false`

  Whether to request block list at login time or not (XEP-0191).
  The default is `true`.

- **roster**: `true | false`

  Whether to request roster at login time or not. The default is `true`.

- **rosterver**: `true | false`

  Whether to set a roster version attribute in roster request or not.
  The default is `true`.

- **private**: `true | false`

  Whether to request bookmarks from private storage at login time or not (XEP-0049).
  The default is `true`.

#### Miscellaneous parameters

- **sasl_mechanisms**: `[string()]`

  A list of SASL mechanisms to use for authentication. Supported mechanisms are
  `PLAIN` and `EXTERNAL`. The appropriate mechanism will be picked automatically.
  If several mechanisms found matching then all of them will be tried in the order
  defined by the value until the authentication is succeed. The default is `[PLAIN]`.
  Note that for `EXTERNAL` authentication you need to have a valid certificate file
  defined in the `certfile` option.

## Parameters of the MQTT scenario

These group of parameters are specific to the MQTT scenario only.
The parameters described here are applied per single session.

**TODO**
