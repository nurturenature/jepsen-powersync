-- change this if changing the DB connection name
\connect postgres;

-- conditionally create lww table
CREATE TABLE IF NOT EXISTS public.lww (
    id uuid NOT NULL DEFAULT gen_random_uuid (),
    k INTEGER NOT NULL UNIQUE,
    v TEXT NOT NULL,
    CONSTRAINT lww_pkey PRIMARY KEY (id)
);

-- tests start from a known state
DELETE FROM lww;

-- insert all rows in a single transaction so
-- PowerSync will initial sync as a whole
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
  INSERT INTO lww (k,v) VALUES (0,'');
  INSERT INTO lww (k,v) VALUES (1,'');
  INSERT INTO lww (k,v) VALUES (2,'');
  INSERT INTO lww (k,v) VALUES (3,'');
  INSERT INTO lww (k,v) VALUES (4,'');
  INSERT INTO lww (k,v) VALUES (5,'');
  INSERT INTO lww (k,v) VALUES (6,'');
  INSERT INTO lww (k,v) VALUES (7,'');
  INSERT INTO lww (k,v) VALUES (8,'');
  INSERT INTO lww (k,v) VALUES (9,'');
  INSERT INTO lww (k,v) VALUES (10,'');
  INSERT INTO lww (k,v) VALUES (11,'');
  INSERT INTO lww (k,v) VALUES (12,'');
  INSERT INTO lww (k,v) VALUES (13,'');
  INSERT INTO lww (k,v) VALUES (14,'');
  INSERT INTO lww (k,v) VALUES (15,'');
  INSERT INTO lww (k,v) VALUES (16,'');
  INSERT INTO lww (k,v) VALUES (17,'');
  INSERT INTO lww (k,v) VALUES (18,'');
  INSERT INTO lww (k,v) VALUES (19,'');
  INSERT INTO lww (k,v) VALUES (20,'');
  INSERT INTO lww (k,v) VALUES (21,'');
  INSERT INTO lww (k,v) VALUES (22,'');
  INSERT INTO lww (k,v) VALUES (23,'');
  INSERT INTO lww (k,v) VALUES (24,'');
  INSERT INTO lww (k,v) VALUES (25,'');
  INSERT INTO lww (k,v) VALUES (26,'');
  INSERT INTO lww (k,v) VALUES (27,'');
  INSERT INTO lww (k,v) VALUES (28,'');
  INSERT INTO lww (k,v) VALUES (29,'');
  INSERT INTO lww (k,v) VALUES (30,'');
  INSERT INTO lww (k,v) VALUES (31,'');
  INSERT INTO lww (k,v) VALUES (32,'');
  INSERT INTO lww (k,v) VALUES (33,'');
  INSERT INTO lww (k,v) VALUES (34,'');
  INSERT INTO lww (k,v) VALUES (35,'');
  INSERT INTO lww (k,v) VALUES (36,'');
  INSERT INTO lww (k,v) VALUES (37,'');
  INSERT INTO lww (k,v) VALUES (38,'');
  INSERT INTO lww (k,v) VALUES (39,'');
  INSERT INTO lww (k,v) VALUES (40,'');
  INSERT INTO lww (k,v) VALUES (41,'');
  INSERT INTO lww (k,v) VALUES (42,'');
  INSERT INTO lww (k,v) VALUES (43,'');
  INSERT INTO lww (k,v) VALUES (44,'');
  INSERT INTO lww (k,v) VALUES (45,'');
  INSERT INTO lww (k,v) VALUES (46,'');
  INSERT INTO lww (k,v) VALUES (47,'');
  INSERT INTO lww (k,v) VALUES (48,'');
  INSERT INTO lww (k,v) VALUES (49,'');
  INSERT INTO lww (k,v) VALUES (50,'');
  INSERT INTO lww (k,v) VALUES (51,'');
  INSERT INTO lww (k,v) VALUES (52,'');
  INSERT INTO lww (k,v) VALUES (53,'');
  INSERT INTO lww (k,v) VALUES (54,'');
  INSERT INTO lww (k,v) VALUES (55,'');
  INSERT INTO lww (k,v) VALUES (56,'');
  INSERT INTO lww (k,v) VALUES (57,'');
  INSERT INTO lww (k,v) VALUES (58,'');
  INSERT INTO lww (k,v) VALUES (59,'');
  INSERT INTO lww (k,v) VALUES (60,'');
  INSERT INTO lww (k,v) VALUES (61,'');
  INSERT INTO lww (k,v) VALUES (62,'');
  INSERT INTO lww (k,v) VALUES (63,'');
  INSERT INTO lww (k,v) VALUES (64,'');
  INSERT INTO lww (k,v) VALUES (65,'');
  INSERT INTO lww (k,v) VALUES (66,'');
  INSERT INTO lww (k,v) VALUES (67,'');
  INSERT INTO lww (k,v) VALUES (68,'');
  INSERT INTO lww (k,v) VALUES (69,'');
  INSERT INTO lww (k,v) VALUES (70,'');
  INSERT INTO lww (k,v) VALUES (71,'');
  INSERT INTO lww (k,v) VALUES (72,'');
  INSERT INTO lww (k,v) VALUES (73,'');
  INSERT INTO lww (k,v) VALUES (74,'');
  INSERT INTO lww (k,v) VALUES (75,'');
  INSERT INTO lww (k,v) VALUES (76,'');
  INSERT INTO lww (k,v) VALUES (77,'');
  INSERT INTO lww (k,v) VALUES (78,'');
  INSERT INTO lww (k,v) VALUES (79,'');
  INSERT INTO lww (k,v) VALUES (80,'');
  INSERT INTO lww (k,v) VALUES (81,'');
  INSERT INTO lww (k,v) VALUES (82,'');
  INSERT INTO lww (k,v) VALUES (83,'');
  INSERT INTO lww (k,v) VALUES (84,'');
  INSERT INTO lww (k,v) VALUES (85,'');
  INSERT INTO lww (k,v) VALUES (86,'');
  INSERT INTO lww (k,v) VALUES (87,'');
  INSERT INTO lww (k,v) VALUES (88,'');
  INSERT INTO lww (k,v) VALUES (89,'');
  INSERT INTO lww (k,v) VALUES (90,'');
  INSERT INTO lww (k,v) VALUES (91,'');
  INSERT INTO lww (k,v) VALUES (92,'');
  INSERT INTO lww (k,v) VALUES (93,'');
  INSERT INTO lww (k,v) VALUES (94,'');
  INSERT INTO lww (k,v) VALUES (95,'');
  INSERT INTO lww (k,v) VALUES (96,'');
  INSERT INTO lww (k,v) VALUES (97,'');
  INSERT INTO lww (k,v) VALUES (98,'');
  INSERT INTO lww (k,v) VALUES (99,'');
COMMIT;

-- create publication for PowerSync
CREATE publication powersync FOR TABLE lww;
