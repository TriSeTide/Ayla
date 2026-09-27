import fs from 'node:fs';
import zlib from 'node:zlib';
const f = process.argv[2];
const buf = fs.readFileSync(f);
let pos=8,w=0,h=0,ct=0;const idat=[];
while(pos<buf.length){const len=buf.readUInt32BE(pos),type=buf.toString('ascii',pos+4,pos+8);
 if(type==='IHDR'){w=buf.readUInt32BE(pos+8);h=buf.readUInt32BE(pos+12);ct=buf[pos+17];}
 if(type==='IDAT')idat.push(buf.subarray(pos+8,pos+8+len));
 if(type==='IEND')break;pos+=12+len;}
const bpp=ct===2?3:ct===6?4:1,raw=zlib.inflateSync(Buffer.concat(idat)),stride=w*bpp,img=Buffer.alloc(h*stride);
let p=0;
for(let y=0;y<h;y++){const ft=raw[p++],cur=raw.subarray(p,p+stride);p+=stride;
 const out=img.subarray(y*stride,(y+1)*stride),prev=y>0?img.subarray((y-1)*stride,y*stride):null;
 for(let x=0;x<stride;x++){const a=x>=bpp?out[x-bpp]:0,b=prev?prev[x]:0,c=(x>=bpp&&prev)?prev[x-bpp]:0;let v=cur[x];
  if(ft===1)v+=a;else if(ft===2)v+=b;else if(ft===3)v+=(a+b)>>1;else if(ft===4){const pa=Math.abs(b-c),pb=Math.abs(a-c),pc=Math.abs(a+b-2*c);v+=(pa<=pb&&pa<=pc)?a:(pb<=pc?b:c);}
  out[x]=v&255;}}
const px=(x,y)=>{const o=y*stride+x*bpp;return '#'+[img[o],img[o+1],img[o+2]].map(v=>v.toString(16).padStart(2,'0')).join('');};
console.log(`image ${w}x${h}`);
const pairs = process.argv.slice(3);
for (const s of pairs){ const [x,y]=s.split(',').map(Number); if(!isNaN(x)&&!isNaN(y)) console.log(`  (${x},${y}) = ${px(x,y)}`); }
