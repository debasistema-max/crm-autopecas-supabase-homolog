"""Read the installed IPS SQLite catalog and build a noncommercial update plan."""

import argparse
import concurrent.futures
import hashlib
import json
import re
import sqlite3
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from contextlib import closing
from pathlib import Path, PurePosixPath

IMAGE_ORIGIN = 'https://pub-1c42f71f3a974244953a13b83a68b545.r2.dev/'
FIELDS = ('url_imagem', 'marca', 'aplicacao', 'categoria', 'montadora', 'oem', 'similar', 'detalhes')
START, END = '[CATALOGO_IPS_INSTALADO]', '[/CATALOGO_IPS_INSTALADO]'


def text(value):
    return str(value or '').replace('\x00', '').replace(START, '(CATALOGO_IPS_INSTALADO)').replace(END, '(/CATALOGO_IPS_INSTALADO)').strip()


def image_url(filename, allowed):
    name = str(filename or '').replace('\\', '/')
    parts = PurePosixPath(name)
    if name not in allowed or parts.is_absolute() or '..' in parts.parts or not re.fullmatch(r'.+\.(?:png|jpg|jpeg|webp)', name, re.I):
        return None
    return IMAGE_ORIGIN + urllib.parse.quote(name, safe='/')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def verify_image(url):
    if not url.startswith(IMAGE_ORIGIN):
        return False
    try:
        request = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'IPS-CRM-Installed-Catalog/1.0'})
        with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
            return response.status == 200 and response.headers.get_content_type().startswith('image/') and int(response.headers.get('Content-Length', '0')) > 0
    except (OSError, ValueError):
        return False


def load_catalog(database, manifest_path):
    manifest = json.loads(Path(manifest_path).read_text(encoding='utf-8-sig'))
    if manifest.get('images', {}).get('base_url') != IMAGE_ORIGIN:
        raise ValueError('Origem das imagens diferente do catalogo IPS revisado.')
    allowed = {row['file'] for row in manifest['images']['files']}
    connection = sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    with closing(connection), connection:
        connection.execute('begin')
        if connection.execute('pragma quick_check').fetchone()[0] != 'ok':
            raise ValueError('Banco local sem integridade.')
        photos = defaultdict(list)
        for row in connection.execute('select product_id,filename from images order by id'):
            url = image_url(row['filename'], allowed)
            if url and url not in photos[row['product_id']]:
                photos[row['product_id']].append(url)
        applications = defaultdict(list)
        for row in connection.execute('select pv.product_id,v.name,v.make,v.category,v.years from product_vehicles pv join vehicles v on v.id=pv.vehicle_id order by pv.product_id,v.id'):
            applications[row['product_id']].append({key: text(row[key]) for key in ('name', 'make', 'category', 'years')})
        records = []
        for row in connection.execute('select p.id,p.code,p.description,p.application,p.oem,p.similar,p.pgroup,p.details,p.ean_gtin,p.altura,p.largura,p.comprimento,b.name as brand from products p join brands b on b.id=p.brand_id order by p.code,p.id'):
            code = str(row['code'] or '').strip()
            if not code or len(code) > 80 or re.search(r'[\x00-\x1f\x7f]', code):
                raise ValueError('Codigo local invalido: ' + repr(code))
            record = {key: text(row[key]) for key in ('description', 'application', 'oem', 'similar', 'pgroup', 'details', 'ean_gtin', 'altura', 'largura', 'comprimento', 'brand')}
            record.update(code=code, images=photos[row['id']], vehicles=applications[row['id']])
            records.append(record)
        duplicates = [code for code, count in Counter(row['code'] for row in records).items() if count > 1]
        if duplicates:
            raise ValueError('Codigos duplicados no catalogo, exigem revisao: ' + ', '.join(duplicates[:20]))
    return records, {'app_version': manifest.get('appVersion'), 'db_version': manifest.get('db', {}).get('version'), 'manifest_images': len(allowed)}


def catalog_details(record):
    lines = ['Origem: Catalogo IPS instalado', 'Descricao: ' + record['description']]
    for label, key in [('Marca', 'brand'), ('Linha do catalogo', 'pgroup'), ('Aplicacao', 'application'), ('OEM', 'oem'), ('Similares', 'similar'), ('Detalhes tecnicos', 'details'), ('EAN/GTIN', 'ean_gtin')]:
        if record.get(key):
            lines.append(label + ': ' + record[key])
    dimensions = [label + ': ' + record[key] for label, key in [('Altura', 'altura'), ('Largura', 'largura'), ('Comprimento', 'comprimento')] if record.get(key)]
    if dimensions:
        lines.append('Dimensoes informadas no catalogo: ' + ' | '.join(dimensions))
    vehicles = list(dict.fromkeys(' | '.join(value for value in (v['make'], v['name'], v['category'], v['years']) if value) for v in record['vehicles']))
    if vehicles:
        lines.append('Veiculos / anos informados no catalogo:\n' + '\n'.join(vehicles))
    return START + '\n' + '\n'.join(lines) + '\n' + END


def merge_details(existing, block):
    current = str(existing or '').strip()
    if START in current or END in current:
        if current.count(START) != 1 or current.count(END) != 1 or current.index(START) > current.index(END):
            raise ValueError('Marcador de origem inconsistente; revisao manual necessaria.')
        prefix, _, tail = current.partition(START)
        _, _, suffix = tail.partition(END)
        current = '\n'.join(value.strip() for value in (prefix, suffix) if value.strip())
    return '\n\n'.join(value for value in (current, block) if value)


def build_plan(records, crm_rows, source, valid_images):
    crm = {row['codigo']: row for row in crm_rows}
    if len(crm) != len(crm_rows):
        raise ValueError('Snapshot CRM com codigos duplicados.')
    changes, unmatched, field_counts = [], [], Counter()
    for record in records:
        current = crm.get(record['code'])
        if current is None:
            unmatched.append(record['code'])
            continue
        before = {field: current.get(field) for field in FIELDS}
        after = dict(before)
        values = {'marca': record['brand'],
                  'aplicacao': '' if current.get('catalog_application') else record['application'],
                  'categoria': '' if current.get('catalog_line') else record['pgroup'],
                  'montadora': ' / '.join(dict.fromkeys(v['make'] for v in record['vehicles'] if v['make'])),
                  'oem': record['oem'], 'similar': record['similar'],
                  'url_imagem': next((url for url in record['images'] if url in valid_images), '')}
        for field, value in values.items():
            if not str(before[field] or '').strip() and value:
                after[field] = value
        after['detalhes'] = merge_details(before['detalhes'], catalog_details(record))
        changed = [field for field in FIELDS if before[field] != after[field]]
        if changed:
            changes.append({'codigo': record['code'], 'before': before, 'after': after, 'changed_fields': changed})
            field_counts.update(changed)
    content = {'source': source, 'records': records, 'valid_images': sorted(valid_images)}
    version = hashlib.sha256(json.dumps(content, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'source': 'IPS_INSTALLED_CATALOG', 'source_version': version, 'origin': source,
            'summary': {'source_products': len(records), 'matched': len(records) - len(unmatched), 'unmatched': len(unmatched),
                        'updated': len(changes), 'unchanged': len(records) - len(unmatched) - len(changes),
                        'verified_images': len(valid_images), 'field_changes': dict(field_counts)},
            'unmatched_codes': unmatched, 'changes': changes}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--crm-snapshot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verified-plan', type=Path, help='Reutilizar somente verificacoes de imagem identicas feitas ha menos de uma hora.')
    args = parser.parse_args()
    records, source = load_catalog(args.database, args.manifest)
    snapshot = json.loads(args.crm_snapshot.read_text(encoding='utf-8-sig'))
    crm_codes = {row['codigo'] for row in snapshot}
    urls = sorted({url for record in records if record['code'] in crm_codes for url in record['images']})
    if args.verified_plan:
        previous = json.loads(args.verified_plan.read_text(encoding='utf-8'))
        if time.time() - args.verified_plan.stat().st_mtime > 3600 or not set(previous.get('unavailable_images', [])).issubset(urls):
            raise ValueError('Verificacao de imagens expirada ou incompativel.')
        valid = set(urls) - set(previous['unavailable_images'])
        same_source = build_plan(records, snapshot, source, valid)['source_version']
        if same_source != previous['source_version'] or len(valid) != previous['summary']['verified_images']:
            raise ValueError('Catalogo alterado; verificar imagens novamente.')
    else:
        valid = set()
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
            results = executor.map(verify_image, urls)
            for url, ok in zip(urls, results):
                if ok:
                    valid.add(url)
    plan = build_plan(records, snapshot, source, valid)
    plan['summary']['unavailable_images'] = len(urls) - len(valid)
    plan['unavailable_images'] = [url for url in urls if url not in valid]
    with args.output.open('x', encoding='utf-8') as destination:
        json.dump(plan, destination, ensure_ascii=False, indent=2)
    print(json.dumps(plan['summary'], ensure_ascii=False))


if __name__ == '__main__':
    main()
