RTB: Benchmarking tool to stress real-time protocols
====================================================

The idea of RTB is to provide a benchmarking tool to stress test
XMPP and MQTT servers with the minimum configuration overhead.
Also, at least in the XMPP world, a "golden standard" benchmark
is highly demanded in order to compare server implementations
avoiding disambiguations as much as possible. RTB is believed
to be used in such role because it has sane defaults (gathered
from statistics of real world servers) and it is able to
stress test all features defined in the
[XMPP Compliance Suite 2018](https://xmpp.org/extensions/xep-0387.html)

# Status

RTB is in an early stage of development: currently only XMPP protocol
is implemented and support for
[Multi-User Chat](https://xmpp.org/extensions/xep-0045.html) and
[Personal Eventing Protocol](https://xmpp.org/extensions/xep-0163.html)
is lacking. Also, "sane" defaults and what should be considered a
"golden benchmark" is yet to be discussed within the XMPP community.
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
 - Erlang/OTP 17.5 or higher. Erlang/OTP 20 is recommended.
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

Once compiled, you will find `rtb.sh` and `rtb.yml.example` files. Copy
`rtb.yml.example` to `rtb.yml`, edit it (see section below) and run:
```
$ cp rtb.yml.example rtb.yml
$ editor rtb.yml
$ ./rtb.sh
```
Investigate the output of the script for presence of errors. All errors
are believed to be self-explanatory and most of them have some hints on
what should be done in order to fix them.

In order to stop the benchmark press `Ctrl+C+C`. In order to start the
benchmark in background append `-detached` switch:
```
$ ./rtb.sh -detached
```
You will find logs in the `log` directory.

# Configuration

All configuration is performed via editing parameters of `rtb.yml` file.
The file has [YAML](http://en.wikipedia.org/wiki/YAML) syntax.
There are mandatory and optional parameters.
There is a group of general parameters which can be used with any
scenario. Another group of parameters is scenario specific.
The majority of parameters are optional, and, except `servers` and
`bind` parameters you are unlikely to change them. Furthermore, for
better performance comparison of different server implementations
changing them is discouraged.

## Mandatory general parameters

- **scenario**: `string()`

  The benchmarking scenario to use. Only `xmpp` is supported.
- **domain**: `string()`

  The option is used for setting a namepart of an XMPP address and, if
  option `servers` is not defined, to resolve the IP address
  and port number of the server to connect.
- **interval**: `non_neg_integer()`

  The option is used to set a timeout to wait before spawning
  next connection. The timeout is set in **milliseconds**.
- **capacity**: `pos_integer()`

  The total amount of connections to be spawned.
- **user**: `string()`

  The pattern for a user part of an XMPP Address. Symbol `%` will
  be replaced with the number of the current connection. For example,
  if the pattern is `user%` and `capacity` is 5, then the following
  users will be generated: `user1@domain, user2@domain, ... user5@domain`.
- **password**: `string()`

  The pattern for a password. The format is the same as for `user` option.
- **certfile**: `string()`

  A path to certificate file in PEM format. The file MUST contain both
  a full certficate chain and a private key. If `EXTERNAL` authentication
  is not used (see `sasl_mechanisms` option) then self-signed certificate
  can be used: the one shipped with the sources is fine.

## Optional parameters

- **servers**: `[uri()]`

  The list of server URIs to connect. The format of the URI must be
  `scheme://hostname:port` where `scheme` can be `tls` or `tcp`, `hostname`
  can be any DNS name or IP address and `port` is a port number.
  Note that all parts of the URI are mandatory. IPv6 addresses MUST be
  enclosed in square brackets, e.g. `tcp://[1:2::3:4]:5222`.
  This option is used to set transport, address and port of the server(s)
  being tested. It's highly recommended to use IP addresses in `hostname`
  part: excessive DNS lookups may create significant overhead for the
  benchmarking tool itself. The default is empty list which means the
  value of `domain` option will be used to obtain the server(s) endpoint.
  Keeping the default is also not recommended for the reason described above.
- **bind**: `[ip_address()]`

  The list of IP addresses of local interfaces to bind. The typical
  usage of the option is to set several binding interfaces in order
  to establish more than 64k outgoing connections from the same machine.
  The default is empty list: in this case a binding address will be chosen
  automatically by the OS.
- **resource**: `string()`

  The option is used to set a resource part of an XMPP address.
  Similarly to the `user` option it may contain `%` symbol for the same purpose.
  The default value is `rtb`.
- **stats_file**: `string()`

  A path to the file where statistics will be dumped. The file is used
  by `gnuplot` to generate statistics graphs. The default value is
  `log/stats.log`
- **www_dir**: `string()`

  A path to a directory where HTML and image files will be created.
  The default is `www`.
- **www_port**: `pos_integer()`

  A port to listen for incoming HTTP requests. The default is `8080`.
- **gnuplot**: `string()`

  The path to a gnuplot executing binary. The default is `gnuplot`.

## Parameters of the XMPP scenario

All parameters are optional.

### Parameters for timing controls.

- **negotiation_timeout**: `pos_integer() | false`

  A timeout to wait for stream negotiation to complete.
  The value is in **seconds**. It can be set to `false` to disable timeout.
  The default is `100` (seconds).
- **connect_timeout**: `pos_integer() | false`

  A timeout to wait for a TCP connection to be established.
  The value is in **seconds**. It can be set to `false` to disable timeout.
  The default is `100` (seconds).
- **reconnect_interval**: `pos_integer() | false`

  A timeout to wait before another reconnection attempt after previous
  connection failure. Initially it is picked randomly between `1` and this
  configured value. Then, exponential back off is applied between several
  consecutive connection failures. The value is in **seconds**.
  It can be set to `false` to disable reconnection attemps completely:
  thus the failed session will never be restored.
  The default is `60` (seconds) - the value recommended by RFC6120.
- **message_interval**: `pos_integer() | false`

  An interval between sending messages. The value is in **seconds**.
  It can be set to `false` to disable sending messages completely.
  The default is `600` (seconds). See also `message_body_size` option.
- **presence_interval**: `pos_integer() | false`

  An interval between sending presence broadcats. The value is in **seconds**.
  It can be set to `false` to disable sending presences completely.
  The default is `600` (seconds). Note that at the first successful login a
  presence broadcast is always sent unless the value is not set to `false`.
- **disconnect_interval**: `pos_integer() | false`

  An interval to wait before forcing disconnect. If stream management
  is enabled (this is the default, see `sm` option), then the session
  will be resumed after a random timeout between `1` and the value of
  `max` attribute of `<enabled/>` element reported by the server.
  Otherwise, the next reconnection attempt will be performed according
  to the value and logic of `reconnect_interval`.
- **proxy65_interval**: `pos_integer() | false`

  An interval between file transfers via Prox65 service (XEP-0065).
  The value is in **seconds**. It can be set to `false` to disable
  this type of file transfer completely. The default is `600` (seconds).
  See also `proxy65_size` option.
- **http_upload_interval**: `pos_integer() | false`

  An interval between file uploads via HTTP Upload service (XEP-0363).
  The value is in **seconds**. It can be set to `false` to disable
  this file uploads completely. The default is `600` (seconds).
  See also `http_upload_size` option.

### Parameters for size control

- **message_body_size**: `non_neg_integer()`

  The size of `<body/>` element of a message in **bytes**.
  Only makes sense when `message_interval` is not set to `false`.
  The default is `100` (bytes).
- **proxy65_size**: `non_neg_integer()`

  The size of a file to transfer via Proxy65 service in **bytes**.
  Only makes sense when `proxy65_interval` is not set to `false`.
  The default is `10485760` (bytes), i.e. 10 megabytes.
- **http_upload_size**: `non_neg_integer()`

  The size of a file to upload via HTTP Upload service in **bytes**.
  Only makes sense when `http_upload_interval` is not set to `false`.
  There is no default value: the option is only needed to set
  if the service doesn't report its maximum file size.

### Parameters for enabling/disabling features

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
  The default is `true`. The requested size of the archive is `20` (messages).
- **carbons**: `true | false`

  Whether to enable message carbons or not (XEP-0280).
  The default is `true`.
- **blocklist**: `true | false`

  Whether to request block list at login time or not (XEP-0191).
  The default is `true`.
- **roster**: `true | false`

  Whether to request roster at login time or not. The default is `true`.
- **rosterver**: `true | false`

  Whether to set roster version attribute or not. The default is `true`.
- **private**: `true | false`

  Whether to request bookmarks from private storage at login time or not (XEP-0049).
  The default is `true`.

### Miscellaneous options

- **sasl_mechanisms**: `[string()]`

  A list of SASL mechanisms to use for authentication. Supported mechanisms are
  `PLAIN` and `EXTERNAL`. The appropriate mechanism will be picked automatically.
  If several mechanisms found matching then all of them will be tried in the order
  defined by the value until the authentication is succeed. The default is `[PLAIN]`.
  Note that for `EXTERNAL` authentication you need to have a valid certificate file
  defined in the `certfile` option.
