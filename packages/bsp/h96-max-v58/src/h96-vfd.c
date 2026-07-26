// h96-vfd — H96 Max V58 front-panel VFD daemon (Armbian).
// Reverse-engineered from the stock Android kernel "fddis" driver:
//   TM1650 protocol, MSB-first, 5us/half-clock, bit-banged on GPIO3 registers.
//   CLK=GPIO3_C7 (line23/bit23)  DAT=GPIO3_D0 (line24/bit24)  base 0xfec40000.
// Shows HH:MM + blinking colon, and lights icons from live system state.
//
// Grid addresses: display-ctrl 0x48; digits 0x6E 0x6C 0x6A 0x68 (left->right);
//   5th "icon" grid 0x66. Icon-grid bit map (decoded from the driver's byte remap):
//     0x01 alarm   0x02 USB    0x04 pause   0x08 play
//     0x10 colon   0x20 ethernet   0x40 WIFI   0x80 unused
#include <linux/gpio.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <time.h>
#include <dirent.h>
#define GPIO3_BASE 0xfec40000UL
#define DR_H (0x0004/4)
#define DDR_H (0x000C/4)
#define CLKBIT 7
#define DATBIT 8
// icon-grid bits
#define I_ALARM 0x01
#define I_USB   0x02
#define I_PAUSE 0x04
#define I_PLAY  0x08
#define I_COLON 0x10
#define I_ETH   0x20
#define I_WIFI  0x40
static volatile uint32_t *g;
static const unsigned char FONT[10]={0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};
static void dly5(void){struct timespec a,b;clock_gettime(CLOCK_MONOTONIC,&a);do{clock_gettime(CLOCK_MONOTONIC,&b);}while(((b.tv_sec-a.tv_sec)*1000000000L+(b.tv_nsec-a.tv_nsec))<5000);}
static void CLK(int v){g[DR_H]=((v?1u:0u)<<CLKBIT)|(1u<<(CLKBIT+16));}
static void DAT(int v){g[DR_H]=((v?1u:0u)<<DATBIT)|(1u<<(DATBIT+16));}
static void DAT_out(void){g[DDR_H]=(1u<<DATBIT)|(1u<<(DATBIT+16));}
static void DAT_in(void){g[DDR_H]=(1u<<(DATBIT+16));}
static void start(void){CLK(1);DAT(1);dly5();DAT(0);dly5();CLK(0);dly5();}
static void stop(void){CLK(0);DAT(0);dly5();CLK(1);dly5();DAT(1);dly5();}
static void wbyte(unsigned char b){for(int i=0;i<8;i++){CLK(0);DAT((b>>7)&1);b<<=1;dly5();CLK(1);dly5();CLK(0);}DAT(1);DAT_in();dly5();CLK(1);dly5();CLK(0);DAT_out();DAT(1);}
static void xfer(unsigned char a,unsigned char d){start();wbyte(a);wbyte(d);stop();}
static int rdf(const char*p,char*b,int n){int fd=open(p,O_RDONLY);if(fd<0)return -1;int r=read(fd,b,n-1);close(fd);if(r<0)r=0;b[r]=0;return r;}
static int link_up(const char*i){char p[128],b[16];snprintf(p,sizeof(p),"/sys/class/net/%s/operstate",i);if(rdf(p,b,sizeof(b))<=0)return 0;return strncmp(b,"up",2)==0;}
static int usb_present(void){DIR*d=opendir("/sys/block");if(!d)return 0;struct dirent*e;int f=0;while((e=readdir(d))){if(e->d_name[0]=='s'&&e->d_name[1]=='d'){f=1;break;}}closedir(d);return f;}
static int audio_playing(void){DIR*d=opendir("/proc/asound");if(!d)return 0;struct dirent*e;int r=0;char pa[256],b[64];while((e=readdir(d))&&!r){if(strncmp(e->d_name,"card",4))continue;for(int p=0;p<4&&!r;p++)for(int s=0;s<2&&!r;s++){snprintf(pa,sizeof(pa),"/proc/asound/%s/pcm%dp/sub%d/status",e->d_name,p,s);if(rdf(pa,b,sizeof(b))>0&&strstr(b,"RUNNING"))r=1;}}closedir(d);return r;}
static volatile int run=1; static void ot(int s){(void)s;run=0;}
int main(void){
    signal(SIGTERM,ot);signal(SIGINT,ot);
    int chip=open("/dev/gpiochip3",O_RDWR);
    if(chip<0){perror("gpiochip3");return 1;}
    struct gpio_v2_line_request req; memset(&req,0,sizeof(req));
    req.offsets[0]=23;req.offsets[1]=24;req.num_lines=2;req.config.flags=GPIO_V2_LINE_FLAG_OUTPUT;
    strncpy(req.consumer,"h96-vfd",sizeof(req.consumer)-1);
    ioctl(chip,GPIO_V2_GET_LINE_IOCTL,&req);   // pin mux to GPIO (handle kept open)
    int fd=open("/dev/mem",O_RDWR|O_SYNC);
    if(fd<0){perror("/dev/mem");return 1;}
    g=mmap(0,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,GPIO3_BASE);
    if(g==MAP_FAILED){perror("mmap");return 1;}
    CLK(1);DAT_out();DAT(1);
    int colon=1,tick=0; unsigned char icons=0;
    while(run){
        if(tick%2==0){                              // refresh state ~1s
            icons=0;
            if(link_up("eth0"))   icons|=I_ETH;
            if(link_up("wlan0"))  icons|=I_WIFI;
            if(usb_present())     icons|=I_USB;
            if(audio_playing())   icons|=I_PLAY;
        }
        time_t t=time(0); struct tm *lt=localtime(&t);
        int hh=lt->tm_hour, mm=lt->tm_min;
        xfer(0x48,0x01);
        xfer(0x6E,FONT[hh/10]); xfer(0x6C,FONT[hh%10]);
        xfer(0x6A,FONT[mm/10]); xfer(0x68,FONT[mm%10]);
        xfer(0x66, icons | (colon?I_COLON:0));
        colon=!colon; tick++;
        usleep(500000);
    }
    return 0;
}
