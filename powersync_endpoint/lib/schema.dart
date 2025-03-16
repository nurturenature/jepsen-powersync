import 'package:powersync/powersync.dart';

final schemaMWW = Schema(([
  Table(
    'mww',
    [Column.integer('k'), Column.integer('v')],
    indexes: [
      Index('mww_k', [IndexedColumn('k')]),
    ],
  ),
]));
