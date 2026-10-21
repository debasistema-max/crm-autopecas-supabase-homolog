import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('installed_ips', Path(__file__).resolve().parents[1] / 'scripts/build_installed_ips_catalog.py')
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


def record(code='00123'):
    return dict(code=code, description='PECA IPS', brand='ISAKA', application='ASTRA 93/95', pgroup='RETROVISOR',
                oem='OEM-1', similar='SIM-1', details='Detalhe local', ean_gtin='7898778850018',
                altura='32', largura='14.5', comprimento='26.5', images=[catalog.IMAGE_ORIGIN + 'RETROVISOR/00123.png'],
                vehicles=[dict(name='ASTRA 93/95', make='GM', category='Linha Leve', years='1993,1994,1995')])


class InstalledCatalogTests(unittest.TestCase):
    def test_images_are_manifest_scoped_and_never_traverse_directories(self):
        allowed = {'RETROVISOR/00123.png', '../secret.png', '/absolute.png', 'file.js'}
        self.assertEqual(catalog.image_url('RETROVISOR/00123.png', allowed), catalog.IMAGE_ORIGIN + 'RETROVISOR/00123.png')
        for value in ['../secret.png', '/absolute.png', 'file.js', 'NOT-LISTED.png']:
            self.assertIsNone(catalog.image_url(value, allowed))

    def test_only_exact_existing_codes_and_verified_photos_are_updated(self):
        source = record()
        current = {'codigo': '00123'}
        plan = catalog.build_plan([source, record('OTHER')], [current], {}, set(source['images']))
        self.assertEqual(plan['summary']['matched'], 1)
        self.assertEqual(plan['unmatched_codes'], ['OTHER'])
        self.assertEqual(plan['changes'][0]['after']['url_imagem'], source['images'][0])
        no_photo = catalog.build_plan([source], [current], {}, set())
        self.assertIsNone(no_photo['changes'][0]['after']['url_imagem'])

    def test_protected_fields_and_nonempty_values_are_never_overwritten(self):
        current = {'codigo': '00123', 'marca': 'Marca manual', 'oem': 'OEM manual', 'url_imagem': 'https://example.test/manual.png',
                   'detalhes': 'Nota do usuario', 'descricao': 'SAP', 'ano': '2026 corrigido', 'preco_sp': 99, 'estoque': 2,
                   'catalog_line': 'Linha oficial', 'catalog_application': 'Aplicacao completa oficial'}
        plan = catalog.build_plan([record()], [current], {}, set(record()['images']))
        after = plan['changes'][0]['after']
        self.assertEqual(set(after), set(catalog.FIELDS))
        for key in ('marca', 'oem', 'url_imagem'):
            self.assertEqual(after[key], current[key])
        self.assertIsNone(after['categoria'])
        self.assertIsNone(after['aplicacao'])
        self.assertTrue(after['detalhes'].startswith('Nota do usuario'))
        for key in ('ano', 'grupo', 'descricao', 'preco_sp', 'estoque', 'ncm', 'ativo'):
            self.assertNotIn(key, after)

    def test_repeating_a_plan_does_not_duplicate_details(self):
        source = record()
        first = catalog.build_plan([source], [{'codigo': source['code']}], {}, set(source['images']))
        next_row = {'codigo': source['code'], **first['changes'][0]['after']}
        second = catalog.build_plan([source], [next_row], {}, set(source['images']))
        self.assertEqual(second['changes'], [])
        self.assertEqual(first['source_version'], second['source_version'])
        self.assertEqual(next_row['detalhes'].count(catalog.START), 1)

    def test_metadata_marker_is_validated_and_user_text_is_retained(self):
        self.assertEqual(catalog.merge_details('Manual', 'Novo bloco'), 'Manual\n\nNovo bloco')
        with self.assertRaises(ValueError):
            catalog.merge_details(catalog.START + '\ncorrompido', 'novo')
        self.assertNotIn(catalog.START, catalog.text('Texto ' + catalog.START))

    def test_duplicate_crm_codes_fail_before_writing(self):
        with self.assertRaises(ValueError):
            catalog.build_plan([record()], [{'codigo': '00123'}, {'codigo': '00123'}], {}, set())

    def test_sqlite_is_read_only_and_duplicate_source_codes_are_blocking(self):
        with tempfile.TemporaryDirectory() as folder:
            database = Path(folder) / 'catalog.db'
            manifest = Path(folder) / 'manifest.json'
            manifest.write_text(json.dumps({'images': {'base_url': catalog.IMAGE_ORIGIN, 'files': []}}))
            connection = sqlite3.connect(database)
            connection.executescript('''
                create table brands(id integer,name text);
                create table products(id integer,brand_id integer,code text,description text,application text,oem text,similar text,pgroup text,details text,ean_gtin text,altura text,largura text,comprimento text);
                create table images(id integer,product_id integer,filename text);
                create table product_vehicles(product_id integer,vehicle_id integer);
                create table vehicles(id integer,name text,make text,category text,years text);
                insert into brands values(1,'IPS');
                insert into products(id,brand_id,code,description) values(1,1,'00123','PECA');
            ''')
            connection.commit()
            before = database.read_bytes()
            rows, _ = catalog.load_catalog(database, manifest)
            self.assertEqual(rows[0]['code'], '00123')
            self.assertEqual(before, database.read_bytes())
            connection.execute("insert into products(id,brand_id,code,description) values(2,1,'00123','OUTRA')")
            connection.commit()
            with self.assertRaises(ValueError):
                catalog.load_catalog(database, manifest)
            connection.close()


if __name__ == '__main__':
    unittest.main()
