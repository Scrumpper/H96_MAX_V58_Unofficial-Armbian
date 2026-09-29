#!/usr/bin/env python3
"""H96 Max V58 — BCM4362A2 Bluetooth bring-up (UART9).
Loads firmware at 3M, chip relaunches at 115200, sets BD addr, RAISES THE
UART BACK TO 3M, then attaches H4 line discipline (no flow control), brings
hci0 UP via HCIDEVUP ioctl (so no bluez is required), and holds the device
open so hci0 persists.

v3.2.3 — the baud raise before attach is the fix for choppy A2DP audio. Every
prior build attached at the post-firmware 115200 and left it there. 115200 8N1
is only ~92 kbps of usable throughput; A2DP SBC stereo needs roughly 229-345
kbps (SBC-XQ more). The audio literally did not fit through the transport, so
playback was audibly choppy while PipeWire reported ZERO xruns - the software
side was handing off data perfectly and the UART was the bottleneck. Stock
Android performs this same post-launch baud switch, which is why Bluetooth
sounds fine there on identical hardware.
Run as a systemd service (Type=simple). Exits non-zero on failure for retry."""
import os,sys,termios,fcntl,struct,time,socket,select as sel_mod
UART="/dev/ttyS9"
HCD="/lib/firmware/brcm/BCM4362A2.hcd"
TIOCMSET=0x5418;TIOCM_RTS=0x004;TIOCM_DTR=0x002
TIOCSETD=0x5423;N_HCI=15;HCIUARTSETPROTO=0x400455C8;HCI_UART_H4=0
AF_BLUETOOTH=31;BTPROTO_HCI=1;HCIDEVUP=0x400448C9
def log(m):sys.stderr.write(m+"\n");sys.stderr.flush()
def setb(fd,b):
    bv={115200:termios.B115200,3000000:termios.B3000000}[b]
    a=termios.tcgetattr(fd);a[0]=0;a[1]=0
    a[2]=termios.CS8|termios.CREAD|termios.CLOCAL;a[3]=0;a[4]=bv;a[5]=bv
    termios.tcsetattr(fd,termios.TCSANOW,a)
def rts(fd):fcntl.ioctl(fd,TIOCMSET,struct.pack("I",TIOCM_RTS|TIOCM_DTR))
def send(fd,op,d=b""):os.write(fd,bytes([0x01,op&0xFF,(op>>8)&0xFF,len(d)])+d)
def rdall(fd,to):
    out=b"";dl=time.monotonic()+to
    while time.monotonic()<dl:
        r,_,_=sel_mod.select([fd],[],[],min(dl-time.monotonic(),0.05))
        if r:
            try:out+=os.read(fd,4096)
            except OSError:pass
    return out
def has_cc(b,op):
    i=0
    while i+6<len(b):
        if b[i]==0x04 and b[i+1]==0x0e and (b[i+4]|(b[i+5]<<8))==op:return b[i+6]==0
        i+=1
    return None
def hci_up():
    """Bring hci0 up via kernel ioctl — no bluez/hciconfig needed."""
    try:
        s=socket.socket(AF_BLUETOOTH,socket.SOCK_RAW,BTPROTO_HCI)
        try:fcntl.ioctl(s,HCIDEVUP,0)   # dev 0 = hci0
        except OSError as e:log("HCIDEVUP: %s"%e)   # EALREADY/EBUSY = already up
        s.close()
    except OSError as e:log("hci socket: %s"%e)

def main():
    if not os.path.exists(HCD): log("firmware missing: "+HCD);return 1
    os.system("pkill -9 -x btattach 2>/dev/null; fuser -k /dev/ttyS9 2>/dev/null; sleep 1")
    try:
        t=os.open(UART,os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK);fcntl.ioctl(t,TIOCSETD,struct.pack("i",0));os.close(t)
    except Exception:pass
    os.system("rfkill unblock bluetooth 2>/dev/null;rfkill block bluetooth 2>/dev/null;sleep 1.5;rfkill unblock bluetooth 2>/dev/null;sleep 2")
    fd=os.open(UART,os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
    setb(fd,115200);fcntl.fcntl(fd,fcntl.F_SETFL,0);rts(fd)
    termios.tcflush(fd,termios.TCIOFLUSH);time.sleep(0.3)
    send(fd,0x0C03);rdall(fd,1)
    send(fd,0x1009);r=rdall(fd,1);bd=None
    i=0
    while i+9<len(r):
        if r[i]==0x04 and r[i+1]==0x0e and (r[i+4]|(r[i+5]<<8))==0x1009:
            bd=r[i+7:i+13];break
        i+=1
    send(fd,0xFC18,bytes([0,0,0xC0,0xC6,0x2D,0]));rdall(fd,1)
    termios.tcdrain(fd);setb(fd,3000000);rts(fd);termios.tcflush(fd,termios.TCIOFLUSH);time.sleep(0.05)
    send(fd,0x0C03);rdall(fd,0.5)
    send(fd,0xFC2E);rdall(fd,0.5)
    data=open(HCD,"rb").read();pos=0;n=0
    while pos+3<=len(data):
        op=data[pos]|(data[pos+1]<<8);pl=data[pos+2];pay=data[pos+3:pos+3+pl]
        send(fd,op,pay)
        if op==0xFC4E:rdall(fd,2);n+=1;break
        rdall(fd,0.04);pos+=3+pl;n+=1
    log("firmware launched (%d records)"%n);time.sleep(0.5)
    setb(fd,115200);rts(fd);termios.tcflush(fd,termios.TCIOFLUSH);time.sleep(0.15)
    send(fd,0x0C03);r=rdall(fd,1.5)
    if has_cc(r,0x0C03) is not True:
        log("chip not responding post-launch @115200");os.close(fd);return 2
    log("chip operational @115200")
    if bd:
        send(fd,0xFC01,bd);rdall(fd,1.0);send(fd,0x0C03);rdall(fd,1.0)
    # raise the UART to 3 Mbps before attaching the line discipline (firmware patch relaunches the chip back to 115200, which caps A2DP well under its needed throughput)
    attach_baud=115200
    send(fd,0xFC18,bytes([0,0,0xC0,0xC6,0x2D,0]));rdall(fd,0.5)
    termios.tcdrain(fd);setb(fd,3000000);rts(fd)
    termios.tcflush(fd,termios.TCIOFLUSH);time.sleep(0.1)
    send(fd,0x0C03);r=rdall(fd,1.5)
    if has_cc(r,0x0C03) is True:
        attach_baud=3000000
        log("UART raised to 3 Mbps (A2DP now has ample headroom)")
    else:
        # fall back to 115200 rather than leave the radio dead; audio is choppy but Bluetooth still works
        log("3 Mbps switch failed - falling back to 115200 (BT audio will be choppy)")
        setb(fd,115200);rts(fd);termios.tcflush(fd,termios.TCIOFLUSH);time.sleep(0.15)
        send(fd,0x0C03);rdall(fd,1.0)
    termios.tcflush(fd,termios.TCIOFLUSH)
    fcntl.ioctl(fd,TIOCSETD,struct.pack("i",N_HCI))
    fcntl.ioctl(fd,HCIUARTSETPROTO,HCI_UART_H4)
    log("hci0 attached (H4, %d)."%attach_baud)
    time.sleep(2)
    hci_up()
    # optional niceties if bluez-tools is installed (harmless if absent)
    os.system("hciconfig hci0 name 'H96-Max-V58' 2>/dev/null; hciconfig hci0 pscan 2>/dev/null")
    log("hci0 up. holding device open.")
    while True: time.sleep(3600)

if __name__=="__main__":
    try: sys.exit(main())
    except Exception as e:
        import traceback;log("EXC: "+traceback.format_exc());sys.exit(1)
