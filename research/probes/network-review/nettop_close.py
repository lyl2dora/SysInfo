# Review probe: does nettop's per-process total drop when a flow closes? (loopback only, own process)
import socket, subprocess, os, time, threading
ARGS=["/usr/bin/nettop","-P","-L","1","-n","-k","time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"]
me=os.getpid()
def mine():
    out=subprocess.run(ARGS,capture_output=True,text=True).stdout
    for l in out.splitlines():
        if l.split(',')[0].endswith('.'+str(me)): return l
    return None
srv=socket.socket(); srv.bind(('127.0.0.1',0)); srv.listen(4); port=srv.getsockname()[1]
def sink(c):
    while c.recv(65536): pass
def acc():
    while True:
        c,_=srv.accept(); threading.Thread(target=sink,args=(c,),daemon=True).start()
threading.Thread(target=acc,daemon=True).start()
print("pid",me,"before any flow:",mine())
a=socket.create_connection(('127.0.0.1',port)); a.sendall(b'x'*5_000_000); time.sleep(0.5)
print("flow A open (5 MB sent):",mine())
a.close(); time.sleep(1.5)
print("flow A closed:",mine())
b=socket.create_connection(('127.0.0.1',port)); b.sendall(b'y'*1_000_000); time.sleep(0.5)
print("flow B open (1 MB sent):",mine())
