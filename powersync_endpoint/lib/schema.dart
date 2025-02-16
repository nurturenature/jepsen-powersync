import 'package:powersync/powersync.dart';

final schemaLWW = Schema(([
  Table(
    'lww',
    [Column.integer('k'), Column.text('v')],
    indexes: [
      Index('lww_k', [IndexedColumn('k')]),
    ],
  ),
]));

final schemaMWW = Schema(([
  Table(
    'mww',
    [Column.integer('k'), Column.integer('v')],
    indexes: [
      Index('mww_k', [IndexedColumn('k')]),
    ],
  ),
]));
