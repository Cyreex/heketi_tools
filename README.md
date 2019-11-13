#Requirements
1. Gluster and Heketi PODs in the namespace "gluster"
2. We have 3 gluster POD
3. All volumes has 3 replicas

#How to start use this scripts:

```
git clone https://github.com/Cyreex/sh.git
cd sh
chmod +x *.sh
```

To start test just run:
```
./search-errors.sh
```

## Lost gluster volumes
If you have warnings like this:
```
 These volumes we have in the Gluster but don't have in the Heketi (lost control):  
 vol_16c8b695505950ccc604e60e68c9de37  
 vol_67c8780e42ef40dafe7c1d2d4dd54871  
```
You can fix it:
```
./add-lost-volume-to-heketi-db.sh vol_67c8780e42ef40dafe7c1d2d4dd54871
``` 

#How to reset files on local server
```
git reset --hard origin/master 
git pull
chmod +x *.sh
```
