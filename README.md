ProXY Wedding
=============

Proxy wedding service is a service where you can
start a server side in the network and the client
side on a local server and allow users to access
the local servers over internet in a general way.

The server need a server config that routes connection
to the correct local client proxy, there may be more than
one "local" machine.

Example server config:

    {xylan, [
       {mode, server},
       {id, "server"},
       {port, [
         46122,                 %% default listen port 
         {"eth0",222},          %% listen port 222 bound to eth0
         {"127.0.0.1", 222}     %% listen port 222 bound to localhost
       },
       {client_port, 29390},    %% port where client connects
       {data_port, 29391},      %% client callback proxy port
       {auth_timeout, 5000},    %% client session auth timeout
       {data_timeout, 5000},    %% user initial data timeout
       {clients, [
         {"home", [
           {server_key,  3177648541185394227},  %% server is signing using this key
           {client_key,  12187761947737533676}, %% client is signing using this key
           {route, [
    	     [{data, "SSH-2.0.*"}],
             [{data, "GET .*"}]
           ]}
         ]},

         {"ssh", [
           {server_key, <<1,2,3,4,5,6,7,8>>},  %% server is signing using this key
           {client_key, "hello"},              %% client is signing using this key
           {route, [
    	     [{ip,"eth0"},{port,222},{data, "SSH-2.0.*"}],
           ]}
         ]}
       ]}
     ]}

Client routing:  "home"

    %% config
    {xylan,
      [{mode, client},
       {id, "home"},
       {server_ip,  "192.168.1.13"},
       {server_port, 29390},
       {server_key,  3177648541185394227},  %% server is signing using this key
       {client_key,  12187761947737533676}, %% client is signing using this key
       {ping_interval, 20000},              %% keep alive interval
       {pong_timeout,  3000},               %% keep alive timeout
       {reconnect_interval, 5000},          %% reconnect "delay"
       {auth_timeout, 4000},                %% timeout to wait for authentication
       {route,[
         { [{data, "SSH-2.0.*"},{port,22}],  [{port,22}] },
         { [{data, "GET .*"}],  [{ip,"127.0.0.1"},{port,8888}] },
         { [{port,23},{src_ip,"216.58.209.132"}],  [{ip,"eth0"},{port,23}] }
       ]}
    ]}.
