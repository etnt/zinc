# zinc - A NETCONF Client in Zig
> A NETCONF client running over TCP and SSH

## Usage

```bash
zig build run -- [options] [file]
```

### Command Line Options

```
-h, --help                 Display help and exit
--netconf10                Use NETCONF 1.0 (default: 1.1)
--hello                    Only send a NETCONF Hello message
--pretty                   Pretty print the output
-u, --user <username>      Username (default: admin)
-p, --password <password>  Password (default: admin)
--proto [tcp | ssh]        Protocol (default: tcp)
--host <host-or-ip>        Host to connect to (default: localhost)
--port <port-number>       Port to connect to (default: 2022)
--groups <groups>          Groups, comma separated
--sup-gids <sup-gids>      Supplementary groups, comma separated
--debug                    Enable debug output
```

If no file is specified, the client reads NETCONF commands from stdin.

## Example Usage

Build and connect to a local NETCONF server and send NETCONF messages,
either from a file or from stdin.
```bash
zig build run -- nc-msg.xml
```

When you have already built the project, you'll find a binary in the `zig-out/bin` directory.

Pipe commands from another program:
```bash
❯ cat nc-msg.xml
<?xml version="1.0" encoding="UTF-8"?>
<rpc xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"  message-id="1">
  <get-config>
    <source>
      <running/>
    </source>
  </get-config>
</rpc>

❯ cat nc-msg.xml | ./zig-out/bin/zinc --host 10.147.40.55 --proto tcp --port 2023  --pretty
<?xml version="1.0" encoding="UTF-8"?>
<rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="1">
  <data>
  ...
```

**Note:** A NETCONF Hello message exchange is automatically made before
sending any NETCONF commands given in the file or via stdin.

To only send a NETCONF Hello message, use the `--hello` flag.

Connect to a specific host with custom credentials:
```bash
zig build run -- --host 192.168.1.100 --port 830 -u operator -p secret --hello
```

Use NETCONF 1.0 with specific groups:
```bash
zig build run -- --netconf10 --groups "netconf,admin" --sup-gids "1000,1001" --hello
```

## TCP Transport Details

When using TCP transport, the client sends a custom (Tail-f) header in the following format:
```
[<username>;<IP>;<proto>;<uid>;<gid>;<xtragids>;<homedir>;<group list>;]
```

This header is automatically generated using the system's user information and the provided command line arguments.
