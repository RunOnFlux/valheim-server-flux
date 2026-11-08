import importlib.machinery, importlib.util, os, struct, sys, tempfile, unittest, io, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader('guard', os.path.join(HERE, '..', 'scripts', 'flux-world-guard'))
spec = importlib.util.spec_from_loader('guard', loader)
guard = importlib.util.module_from_spec(spec)
loader.exec_module(guard)


def write_gen(world, n, chunks=((0, 0, 0, 1),), skip=(), ok=True):
    """One whole save, in the layout a real Valheim 1.0 server wrote (checked on a live server)."""
    idx = struct.pack('<hii', 42, 81, len(chunks)) + b''.join(
        bytes([x, y, l]) + struct.pack('<ii', v, 81) for x, y, l, v in chunks)
    files = {'fwl2': b'x' * 52, 'db2': b'd' * 100, 'chunks': idx, 'ok': struct.pack('<i', 42)}
    for ext, data in files.items():
        if ext in skip or (ext == 'ok' and not ok):
            continue
        with open(os.path.join(world, '_main.%d.%s' % (n, ext)), 'wb') as fh:
            fh.write(data)
    for x, y, l, v in chunks:
        with open(os.path.join(world, '%02d_%02d__%d_%d.chunk' % (x, y, l, v)), 'wb') as fh:
            fh.write(b'c')


class Guard(unittest.TestCase):
    def setUp(self):
        self.cfg = tempfile.mkdtemp()
        self.world = os.path.join(self.cfg, 'worlds_local', 'W')
        os.makedirs(self.world)
        os.environ['FLUX_CONFIG_DIR'] = self.cfg
        os.environ['WORLD_NAME'] = 'W'

    def run_guard(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            rc = guard.main()
        return rc, out.getvalue()

    def names(self):
        return sorted(os.listdir(self.world))

    def test_healthy_world_untouched(self):
        write_gen(self.world, 5)
        before = self.names()
        self.assertEqual(self.run_guard()[0], 0)
        self.assertEqual(self.names(), before)

    def test_empty_folder_and_missing_folder_are_new_servers(self):
        self.assertEqual(self.run_guard()[0], 0)
        os.rmdir(self.world)
        self.assertEqual(self.run_guard()[0], 0)

    def test_header_only_world_is_a_new_world_not_a_refusal(self):
        with open(os.path.join(self.world, '_main.0.fwl2'), 'wb') as fh:
            fh.write(b'x' * 52)
        self.assertEqual(self.run_guard()[0], 0)

    def test_conflict_file_is_moved_aside_and_world_kept(self):
        write_gen(self.world, 259)
        c = os.path.join(self.world, '_main.259.sync-conflict-20260930-165322-XUVBXFM.db2')
        open(c, 'wb').write(b'x')
        rc, out = self.run_guard()
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(c))
        self.assertTrue(os.path.exists(os.path.join(self.cfg, 'sync-conflicts', os.path.basename(c))))
        self.assertIn('_main.259.ok', self.names())

    def test_mixed_generation_falls_back_to_the_older_complete_one(self):
        write_gen(self.world, 10)
        write_gen(self.world, 11, skip=('db2', 'chunks'))   # new marker, old data not there
        rc, out = self.run_guard()
        self.assertEqual(rc, 0)
        self.assertNotIn('_main.11.ok', self.names())
        self.assertIn('_main.10.ok', self.names())
        self.assertIn('load save _main.10', out)
        self.assertTrue(os.path.exists(os.path.join(self.cfg, 'sync-conflicts', '_main.11.ok')))

    def test_fallback_needs_its_chunks(self):
        write_gen(self.world, 10, chunks=((0, 0, 0, 1),))
        os.remove(os.path.join(self.world, '00_00__0_1.chunk'))   # reaped by a newer save
        write_gen(self.world, 11, skip=('db2',), chunks=((0, 0, 0, 2),))
        rc, _ = self.run_guard()
        self.assertEqual(rc, 3)
        self.assertIn('_main.11.ok', self.names())               # nothing was moved

    def test_no_complete_save_refuses_and_touches_nothing(self):
        write_gen(self.world, 3, skip=('chunks',))
        before = self.names()
        rc, out = self.run_guard()
        self.assertEqual(rc, 3)
        self.assertEqual(self.names(), before)
        self.assertIn('refusing to start', out)

    def test_data_without_a_marker_refuses(self):
        write_gen(self.world, 3, ok=False)
        self.assertEqual(self.run_guard()[0], 3)

    def test_pre_1_0_flat_world_is_not_judged(self):
        os.makedirs(os.path.join(self.cfg, 'worlds_local'), exist_ok=True)
        open(os.path.join(self.cfg, 'worlds_local', 'W.db'), 'wb').write(b'x')
        open(os.path.join(self.cfg, 'worlds_local', 'W.fwl'), 'wb').write(b'x')
        os.rmdir(self.world)
        self.assertEqual(self.run_guard()[0], 0)

    def test_chunk_mismatch_on_the_newest_is_reported_not_acted_on(self):
        write_gen(self.world, 7, chunks=((0, 0, 0, 1), (1, 0, 0, 1)))
        os.remove(os.path.join(self.world, '01_00__0_1.chunk'))
        before = self.names()
        rc, out = self.run_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(self.names(), before)
        self.assertIn('not acted on', out)

    def test_other_worlds_are_left_alone(self):
        other = os.path.join(self.cfg, 'worlds_local', 'Other')
        os.makedirs(other)
        write_gen(other, 3, skip=('chunks',))
        write_gen(self.world, 1)
        self.assertEqual(self.run_guard()[0], 0)


if __name__ == '__main__':
    unittest.main()
