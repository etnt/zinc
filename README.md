# zig-tcp - write stuff over TCP
> Just some Zig experimenting

In one shell start netcat:

```bash
nc -l 127.0.0.1 -p 8080
 ```

Then run:

```bash
zig build run
```

In the netcat shell you should see `Hello World`. Now, type in some XML, e.g: `<html><body><h1>Hello</h1></body></html>`. In the zig-tcp shell you should see the XML Pretty Printed.
