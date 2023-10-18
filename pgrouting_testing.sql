CREATE EXTENSION postgis;
CREATE EXTENSION pgrouting;

ALTER TABLE osm_roads
ALTER COLUMN geom 
TYPE Geometry(linestring, 2180) 
USING ST_Transform(geom, 2180);

CREATE SCHEMA route;

--creating car drivable net
CREATE TABLE route.roads AS 
WITH g AS 
(SELECT st_union(geom) AS geom FROM powiaty where jpt_nazwa_ in ('powiat Poznań', 'powiat poznański' ))
SELECT r.* AS geom FROM osm_roads r join g 
ON st_contains(g.geom, r.geom) where
fclass not in ('bridleway','footway', 'steps', 'path', 'busway', 'service','pedestrian', 'cycleway');
alter table route.roads add primary key (gid);

ALTER TABLE route.roads 
ADD COLUMN source integer,
ADD COLUMN target integer,
ADD COLUMN cost_len double precision;

UPDATE route.roads SET cost_len = ST_Length(geom);

SELECT pgr_createTopology('route.roads', 0.01,'geom','gid');
SELECT pgr_nodeNetwork('route.roads', 0.01, 'gid', 'geom');
SELECT pgr_analyzeGraph('route.roads', 0.01,'geom','gid');


--network corection
ALTER TABLE route.roads_noded 
ADD COLUMN cost_len double precision,
ADD COLUMN rcost_len double precision;
ADD COLUMN oneway character varying(1),
ADD COLUMN maxspeed smallint;

UPDATE route.roads_noded SET cost_len = ST_Length(geom);
UPDATE route.roads_noded SET rcost_len = ST_Length(geom);

SELECT pgr_createTopology('route.roads_noded', 0.01,'geom','id');
SELECT pgr_analyzeGraph('route.roads_noded', 0.01,'geom','id');


update route.roads_noded 
set oneway = r.oneway from route.roads r where old_id =gid;

ALTER TABLE route.roads_noded 
ADD COLUMN one_way integer;

update route.roads_noded 
set one_way = 0 --both directional
where oneway='B';

update route.roads_noded 
set one_way = 1 --one directional
where oneway='F';

update route.roads_noded 
set one_way = -1 --rev one directional
where oneway='T';

update route.roads_noded 
set maxspeed = r.maxspeed from route.roads r where old_id =gid;

ALTER TABLE route.roads_noded
ADD COLUMN x1 double precision,
ADD COLUMN y1 double precision,
ADD COLUMN x2 double precision,
ADD COLUMN y2 double precision;

UPDATE route.roads_noded
SET x1 = st_x(st_startpoint(geom)),
    y1 = st_y(st_startpoint(geom)),
    x2 = st_x(st_endpoint(geom)),
    y2 = st_y(st_endpoint(geom));


--“F” means that only driving
--in direction of the linestring is allowed. “T” means
--that only driving against the direction of the
--linestring is allowed. “B” (default value) means that
--traffic is permitted in both directions.

--algorithm tests
SELECT seq, node, edge,cost,agg_cost,geom 
FROM pgr_dijkstra('SELECT id,
source::integer, target::integer,
cost_len::double precision AS cost
FROM route.roads_noded',12066,330, false)AS di
join route.roads_noded pt ON di.edge=pt.id;


SELECT * FROM pgr_aStar(
'SELECT id, source::INTEGER, target::bigint,
cost_len::double precision AS cost,x1,y1,x2,y2
FROM route.roads_noded',1852,2135,true
);

with dd as (
SELECT *
FROM pgr_drivingDistance(
'SELECT id, source, target, cost_len::double precision as cost 
FROM route.roads_noded',330,3000)
)
SELECT ST_ConcaveHull(st_collect(geom),0.3) as geom FROM route.roads_noded net 
inner join dd on net.id=dd.edge;



