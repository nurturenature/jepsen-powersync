-- change this if changing the DB connection name
\connect postgres;

-- conditionally create mww table
CREATE TABLE IF NOT EXISTS public.mww (
    id TEXT NOT NULL,
    k INTEGER NOT NULL UNIQUE,
    v INTEGER NOT NULL,
    CONSTRAINT mww_pkey PRIMARY KEY (id)
);

-- initialize in a single transaction so
-- PowerSync will initially sync as a whole
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
  -- tests start from a known state
  DELETE FROM mww;

  -- insert all id/k that will be used with a known v
  INSERT INTO mww (id,k,v) VALUES ('0',0,-1);
  INSERT INTO mww (id,k,v) VALUES ('1',1,-1);
  INSERT INTO mww (id,k,v) VALUES ('2',2,-1);
  INSERT INTO mww (id,k,v) VALUES ('3',3,-1);
  INSERT INTO mww (id,k,v) VALUES ('4',4,-1);
  INSERT INTO mww (id,k,v) VALUES ('5',5,-1);
  INSERT INTO mww (id,k,v) VALUES ('6',6,-1);
  INSERT INTO mww (id,k,v) VALUES ('7',7,-1);
  INSERT INTO mww (id,k,v) VALUES ('8',8,-1);
  INSERT INTO mww (id,k,v) VALUES ('9',9,-1);
  INSERT INTO mww (id,k,v) VALUES ('10',10,-1);
  INSERT INTO mww (id,k,v) VALUES ('11',11,-1);
  INSERT INTO mww (id,k,v) VALUES ('12',12,-1);
  INSERT INTO mww (id,k,v) VALUES ('13',13,-1);
  INSERT INTO mww (id,k,v) VALUES ('14',14,-1);
  INSERT INTO mww (id,k,v) VALUES ('15',15,-1);
  INSERT INTO mww (id,k,v) VALUES ('16',16,-1);
  INSERT INTO mww (id,k,v) VALUES ('17',17,-1);
  INSERT INTO mww (id,k,v) VALUES ('18',18,-1);
  INSERT INTO mww (id,k,v) VALUES ('19',19,-1);
  INSERT INTO mww (id,k,v) VALUES ('20',20,-1);
  INSERT INTO mww (id,k,v) VALUES ('21',21,-1);
  INSERT INTO mww (id,k,v) VALUES ('22',22,-1);
  INSERT INTO mww (id,k,v) VALUES ('23',23,-1);
  INSERT INTO mww (id,k,v) VALUES ('24',24,-1);
  INSERT INTO mww (id,k,v) VALUES ('25',25,-1);
  INSERT INTO mww (id,k,v) VALUES ('26',26,-1);
  INSERT INTO mww (id,k,v) VALUES ('27',27,-1);
  INSERT INTO mww (id,k,v) VALUES ('28',28,-1);
  INSERT INTO mww (id,k,v) VALUES ('29',29,-1);
  INSERT INTO mww (id,k,v) VALUES ('30',30,-1);
  INSERT INTO mww (id,k,v) VALUES ('31',31,-1);
  INSERT INTO mww (id,k,v) VALUES ('32',32,-1);
  INSERT INTO mww (id,k,v) VALUES ('33',33,-1);
  INSERT INTO mww (id,k,v) VALUES ('34',34,-1);
  INSERT INTO mww (id,k,v) VALUES ('35',35,-1);
  INSERT INTO mww (id,k,v) VALUES ('36',36,-1);
  INSERT INTO mww (id,k,v) VALUES ('37',37,-1);
  INSERT INTO mww (id,k,v) VALUES ('38',38,-1);
  INSERT INTO mww (id,k,v) VALUES ('39',39,-1);
  INSERT INTO mww (id,k,v) VALUES ('40',40,-1);
  INSERT INTO mww (id,k,v) VALUES ('41',41,-1);
  INSERT INTO mww (id,k,v) VALUES ('42',42,-1);
  INSERT INTO mww (id,k,v) VALUES ('43',43,-1);
  INSERT INTO mww (id,k,v) VALUES ('44',44,-1);
  INSERT INTO mww (id,k,v) VALUES ('45',45,-1);
  INSERT INTO mww (id,k,v) VALUES ('46',46,-1);
  INSERT INTO mww (id,k,v) VALUES ('47',47,-1);
  INSERT INTO mww (id,k,v) VALUES ('48',48,-1);
  INSERT INTO mww (id,k,v) VALUES ('49',49,-1);
  INSERT INTO mww (id,k,v) VALUES ('50',50,-1);
  INSERT INTO mww (id,k,v) VALUES ('51',51,-1);
  INSERT INTO mww (id,k,v) VALUES ('52',52,-1);
  INSERT INTO mww (id,k,v) VALUES ('53',53,-1);
  INSERT INTO mww (id,k,v) VALUES ('54',54,-1);
  INSERT INTO mww (id,k,v) VALUES ('55',55,-1);
  INSERT INTO mww (id,k,v) VALUES ('56',56,-1);
  INSERT INTO mww (id,k,v) VALUES ('57',57,-1);
  INSERT INTO mww (id,k,v) VALUES ('58',58,-1);
  INSERT INTO mww (id,k,v) VALUES ('59',59,-1);
  INSERT INTO mww (id,k,v) VALUES ('60',60,-1);
  INSERT INTO mww (id,k,v) VALUES ('61',61,-1);
  INSERT INTO mww (id,k,v) VALUES ('62',62,-1);
  INSERT INTO mww (id,k,v) VALUES ('63',63,-1);
  INSERT INTO mww (id,k,v) VALUES ('64',64,-1);
  INSERT INTO mww (id,k,v) VALUES ('65',65,-1);
  INSERT INTO mww (id,k,v) VALUES ('66',66,-1);
  INSERT INTO mww (id,k,v) VALUES ('67',67,-1);
  INSERT INTO mww (id,k,v) VALUES ('68',68,-1);
  INSERT INTO mww (id,k,v) VALUES ('69',69,-1);
  INSERT INTO mww (id,k,v) VALUES ('70',70,-1);
  INSERT INTO mww (id,k,v) VALUES ('71',71,-1);
  INSERT INTO mww (id,k,v) VALUES ('72',72,-1);
  INSERT INTO mww (id,k,v) VALUES ('73',73,-1);
  INSERT INTO mww (id,k,v) VALUES ('74',74,-1);
  INSERT INTO mww (id,k,v) VALUES ('75',75,-1);
  INSERT INTO mww (id,k,v) VALUES ('76',76,-1);
  INSERT INTO mww (id,k,v) VALUES ('77',77,-1);
  INSERT INTO mww (id,k,v) VALUES ('78',78,-1);
  INSERT INTO mww (id,k,v) VALUES ('79',79,-1);
  INSERT INTO mww (id,k,v) VALUES ('80',80,-1);
  INSERT INTO mww (id,k,v) VALUES ('81',81,-1);
  INSERT INTO mww (id,k,v) VALUES ('82',82,-1);
  INSERT INTO mww (id,k,v) VALUES ('83',83,-1);
  INSERT INTO mww (id,k,v) VALUES ('84',84,-1);
  INSERT INTO mww (id,k,v) VALUES ('85',85,-1);
  INSERT INTO mww (id,k,v) VALUES ('86',86,-1);
  INSERT INTO mww (id,k,v) VALUES ('87',87,-1);
  INSERT INTO mww (id,k,v) VALUES ('88',88,-1);
  INSERT INTO mww (id,k,v) VALUES ('89',89,-1);
  INSERT INTO mww (id,k,v) VALUES ('90',90,-1);
  INSERT INTO mww (id,k,v) VALUES ('91',91,-1);
  INSERT INTO mww (id,k,v) VALUES ('92',92,-1);
  INSERT INTO mww (id,k,v) VALUES ('93',93,-1);
  INSERT INTO mww (id,k,v) VALUES ('94',94,-1);
  INSERT INTO mww (id,k,v) VALUES ('95',95,-1);
  INSERT INTO mww (id,k,v) VALUES ('96',96,-1);
  INSERT INTO mww (id,k,v) VALUES ('97',97,-1);
  INSERT INTO mww (id,k,v) VALUES ('98',98,-1);
  INSERT INTO mww (id,k,v) VALUES ('99',99,-1);
COMMIT;

-- create publication for PowerSync
CREATE PUBLICATION powersync FOR TABLE mww;
