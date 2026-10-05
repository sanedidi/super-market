import pandas as pd, re, json, gzip
from mapping import category
df=pd.read_pickle('goods_cat.pkl')
df['cat']=[category(p,re.sub(r'^\d+\s*-\s*','',s),n) for p,s,n in zip(df.pos,df.subposition,df.name)]
strip=lambda s: re.sub(r'^\d+\s*-\s*','',s).strip()
def clean(s):
    s=re.sub(r'\s+',' ',(s or '')).strip().strip(' ,.;')
    return '' if s in ('---','-','--') else s
def pretty_brand(b):
    b=clean(b)
    if not b: return ''
    letters=[c for c in b if c.isalpha()]
    if letters and all(c.isupper() for c in letters) and len(b)>3:
        return re.sub(r"[A-Za-zА-Яа-яЁё]+", lambda m: m.group(0).capitalize(), b.lower())
    return b
def fix_case(a):
    letters=[c for c in a if c.isalpha()]
    if len(letters)>6 and sum(c.isupper() for c in letters)/len(letters)>0.8:
        a=a.lower()
    return a[:1].upper()+a[1:] if a else a
lm=pd.read_csv('lavka_matches.csv',dtype=str)
lm['score']=lm.score.astype(float)
lm=lm[(lm.score>=0.45)&~lm.barcode.duplicated(keep=False)]
attach=dict(zip(lm.barcode,lm.lavka))
items=[]
for r in df.itertuples():
    brand=pretty_brand(strip(r.brand))
    attr=fix_case(clean(r.attribute))
    sub=strip(r.subposition)
    typ=re.sub(r'\s*\(.*?\)','',sub).split(',')[0].strip()
    if re.search(r'всех видов|прочие|прочих|не перечисл',typ.lower()): typ=''
    stems=[w[:min(len(w)-1,5)] for w in re.findall(r'[а-яёa-z]{4,}',typ.lower())]
    has_type=any(st in attr.lower() for st in stems) if stems else True
    if brand and attr:
        a2 = attr[:1].lower()+attr[1:] if attr[:2].isalpha() and not attr[:2].isupper() else attr
        if attr.lower().startswith(brand.lower()): name=attr
        elif not has_type and typ: name=f'{typ} {brand}, {a2}'
        else: name=f'{brand}, {a2}'
    elif brand:
        name=f'{sub}, {brand}'
    elif attr:
        name=f'{sub}, {attr[:1].lower()+attr[1:]}' if not attr.lower().startswith(sub.lower()[:8]) else attr
    else:
        name=clean(r.name)
    name=re.sub(r'\s+',' ',name).strip(' ,.')
    sec,subcat=r.cat.split(' / ')
    u=(r.units or '').strip().lower()
    unit='кг' if u=='килограмм' else 'шт'
    attrs={'source':'tasnif.soliq.uz','ikpu_name':clean(r.name)}
    if clean(r.units): attrs['package']=clean(r.units)
    if r.label=='1': attrs['marked']=True
    it={'barcode':r.barcode,'name':name,'brand':brand,'category':[sec,subcat],'unit':unit,'ikpu':r.mxik,'attributes':attrs}
    if r.barcode in attach: it['attach_to']=attach[r.barcode]
    items.append(it)
print(len(items), sum('attach_to' in i for i in items))
import random; random.seed(5)
for i in random.sample(items,15): print(i['name'],'|',' / '.join(i['category']),'|',i['brand'])
# chunks of 500 per request, files of ~25k items each, gz
for k in range(0,len(items),25000):
    with gzip.open(f'/mnt/user-data/outputs/tasnif_import_{k//25000+1}.json.gz','wt',encoding='utf-8') as f:
        json.dump(items[k:k+25000],f,ensure_ascii=False,separators=(',',':'))
