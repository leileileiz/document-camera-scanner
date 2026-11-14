#include <leptonica/allheaders.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <math.h>
#include <string.h>
static PIX *normalize(PIX *rgb) {
 int w=pixGetWidth(rgb),h=pixGetHeight(rgb);
 PIX *small=pixScaleToSize(rgb,(w+3)/4,(h+3)/4);
 if(!small)return NULL;
 PIX *maps[3]={NULL,NULL,NULL};
 for(int c=0;c<3;c++) {
  PIX *channel=pixGetRGBComponent(small,c);
  if(!channel)return NULL;
  PIX *closed=pixCloseGray(channel,31,31);
  if(!closed)return NULL;
  PIX *smooth=pixBlockconv(closed,12,12);
  if(!smooth)return NULL;
  maps[c]=pixScaleToSize(smooth,w,h);
  pixDestroy(&channel);pixDestroy(&closed);pixDestroy(&smooth);
  if(!maps[c])return NULL;
 }
 PIX *out=pixCreate(w,h,32);if(!out)return NULL;
 for(int y=0;y<h;y++) {
  l_uint32 *in=pixGetData(rgb)+y*pixGetWpl(rgb),*dst=pixGetData(out)+y*pixGetWpl(out);
  for(int x=0;x<w;x++) {
   int v[3];extractRGBValues(in[x],&v[0],&v[1],&v[2]);
   for(int c=0;c<3;c++) {
    int bg=GET_DATA_BYTE(pixGetData(maps[c])+y*pixGetWpl(maps[c]),x);
    v[c]=(int)fmin(255.0,235.0*v[c]/fmax(40,bg));
   }
   composeRGBPixel(v[0],v[1],v[2],&dst[x]);
  }
 }
 for(int c=0;c<3;c++)pixDestroy(&maps[c]);pixDestroy(&small);return out;
}
// One bounded job per process. Exit on any allocation or codec failure.
int main(int argc,char **argv) {
 if(argc!=4 || (strcmp(argv[3],"homework") && strcmp(argv[3],"scan")))return 2;
 PIX *src=pixRead(argv[1]); if(!src)return 3;
 int w=pixGetWidth(src),h=pixGetHeight(src);
 if(w<64 || h<64 || w>12000000/h){pixDestroy(&src);return 3;}
 PIX *rgb=pixConvertTo32(src);pixDestroy(&src);if(!rgb)return 4;
 PIX *norm=normalize(rgb);pixDestroy(&rgb);if(!norm)return 4;
 PIX *tone=pixGammaTRC(NULL,norm,0.85,0,232);if(!tone)return 5;
 PIX *work=pixUnsharpMasking(tone,1,0.30);pixDestroy(&tone);if(!work)return 5;
 if(!strcmp(argv[3],"homework")) {int status=pixWrite(argv[2],work,IFF_PNG);pixDestroy(&norm);pixDestroy(&work);return status?6:0;}
 PIX *gray=pixConvertRGBToGray(norm,0.3,0.6,0.1),*bw=NULL;pixDestroy(&norm);if(!gray)return 6;
 if(pixSauvolaBinarizeTiled(gray,25,0.12,1,1,NULL,&bw)||!bw)return 6;
 PIX *scan=pixConvertRGBToGray(work,0.3,0.6,0.1);pixDestroy(&work);if(!scan)return 7;
 for(int y=0;y<h;y++) {
  l_uint32 *b=pixGetData(bw)+y*pixGetWpl(bw),*g=pixGetData(scan)+y*pixGetWpl(scan),*n=pixGetData(gray)+y*pixGetWpl(gray);
  for(int x=0;x<w;x++)if(GET_DATA_BIT(b,x) && GET_DATA_BYTE(n,x)<185)SET_DATA_BYTE(g,x,0);
 }
 int status=pixWrite(argv[2],scan,IFF_PNG);
 pixDestroy(&gray);pixDestroy(&bw);pixDestroy(&scan);return status?8:0;
}
